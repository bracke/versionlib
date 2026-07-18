with Ada.Containers.Ordered_Maps;
with Ada.Containers.Vectors;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Version.Objects; use type Version.Objects.Object_Id_Storage;
use type Version.Objects.Object_Kind;
with Version.Object_Cache;
with Version.Ref_Format;
with Version.Refs;
with Version.Revisions;

package body Version.Name_Rev is

   use Ada.Strings.Unbounded;

   --  git's MERGE_TRAVERSAL_WEIGHT: descending through a merge's second or
   --  later parent is treated as a very long hop, so a name reached that way
   --  loses to any first-parent name.
   Merge_Traversal_Weight : constant := 65_535;

   type Rev_Name is record
      Tip_Name   : Unbounded_String;
      Taggerdate : Long_Long_Integer := 0;
      Generation : Natural := 0;
      Distance   : Natural := 0;
      From_Tag   : Boolean := False;
   end record;

   package Name_Maps is new Ada.Containers.Ordered_Maps
     (Key_Type     => Version.Objects.Object_Id_Storage,
      Element_Type => Rev_Name);

   package Id_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Version.Objects.Object_Id_Storage);

   function Image (N : Natural) return String is
     (Ada.Strings.Fixed.Trim (Natural'Image (N), Ada.Strings.Both));

   --  git's effective_distance: any name that needed a first-parent step
   --  after a merge hop is pushed behind the ones that did not.
   function Effective_Distance (Distance, Generation : Natural) return Natural
   is (Distance + (if Generation > 0 then Merge_Traversal_Weight else 0));

   --  git's is_better_name.
   function Is_Better
     (Current    : Rev_Name;
      Taggerdate : Long_Long_Integer;
      Generation : Natural;
      Distance   : Natural;
      From_Tag   : Boolean) return Boolean
   is
      Cur_Distance : constant Natural :=
        Effective_Distance (Current.Distance, Current.Generation);
      New_Distance : constant Natural :=
        Effective_Distance (Distance, Generation);
   begin
      --  Between two tags, the nearer one wins.
      if From_Tag and then Current.From_Tag then
         return Cur_Distance > New_Distance;
      end if;

      --  A tag beats a non-tag.
      if Current.From_Tag /= From_Tag then
         return From_Tag;
      end if;

      --  Two non-tags: shorter hop, then older date.
      if Cur_Distance /= New_Distance then
         return Cur_Distance > New_Distance;
      end if;
      if Current.Taggerdate /= Taggerdate then
         return Current.Taggerdate > Taggerdate;
      end if;
      return False;
   end Is_Better;

   --  git's get_parent_name: the name for a commit reached through parent
   --  number Parent (> 1) of a commit already named by Name.
   function Parent_Name (Name : Rev_Name; Parent : Positive) return String is
      Tip  : constant String := To_String (Name.Tip_Name);
      Base : constant String :=
        (if Tip'Length >= 2
           and then Tip (Tip'Last - 1 .. Tip'Last) = "^0"
         then Tip (Tip'First .. Tip'Last - 2) else Tip);
   begin
      if Name.Generation > 0 then
         return Base & "~" & Image (Name.Generation) & "^" & Image (Parent);
      end if;
      return Base & "^" & Image (Parent);
   end Parent_Name;

   --  The name git prints for a stored entry.
   function Render (Name : Rev_Name) return String is
      Tip  : constant String := To_String (Name.Tip_Name);
      Base : constant String :=
        (if Tip'Length >= 2
           and then Tip (Tip'Last - 1 .. Tip'Last) = "^0"
         then Tip (Tip'First .. Tip'Last - 2) else Tip);
   begin
      if Name.Generation = 0 then
         return Tip;
      end if;
      return Base & "~" & Image (Name.Generation);
   end Render;

   --  The tagger timestamp of an annotated tag object, which git uses to
   --  break ties between two tags naming the same commit (older wins).
   function Tagger_Time (Content : String) return Long_Long_Integer is
      LF     : constant Character := Character'Val (10);
      Prefix : constant String := "tagger ";
      Pos    : Natural := Content'First;
   begin
      while Pos <= Content'Last loop
         declare
            EOL : Natural := Content'Last + 1;
         begin
            for K in Pos .. Content'Last loop
               if Content (K) = LF then
                  EOL := K;
                  exit;
               end if;
            end loop;

            exit when Pos = EOL;   --  blank line ends the header

            declare
               Line : constant String := Content (Pos .. EOL - 1);
            begin
               if Line'Length > Prefix'Length
                 and then Line (Line'First .. Line'First + Prefix'Length - 1)
                          = Prefix
               then
                  --  "tagger Name <mail> <seconds> <tz>"
                  declare
                     Last_Sp : Natural := 0;
                     Prev_Sp : Natural := 0;
                  begin
                     for I in reverse Line'Range loop
                        if Line (I) = ' ' then
                           if Last_Sp = 0 then
                              Last_Sp := I;
                           else
                              Prev_Sp := I;
                              exit;
                           end if;
                        end if;
                     end loop;
                     if Prev_Sp = 0 or else Last_Sp = 0 then
                        return 0;
                     end if;
                     return Long_Long_Integer'Value
                       (Line (Prev_Sp + 1 .. Last_Sp - 1));
                  end;
               end if;
            end;

            Pos := EOL + 1;
         end;
      end loop;

      return 0;
   exception
      when Constraint_Error =>
         return 0;
   end Tagger_Time;

   function Describe_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Target    : Version.Objects.Hex_Object_Id;
      Tags_Only : Boolean := False)
      return String
   is
      Objects : Version.Object_Cache.Object_Cache;
      Names   : Name_Maps.Map;

      --  Record a name for Id when it beats whatever is there, reporting
      --  whether the walk should continue through it (git's
      --  create_or_update_name returning non-NULL).
      procedure Offer
        (Id         : Version.Objects.Object_Id_Storage;
         Tip_Name   : String;
         Taggerdate : Long_Long_Integer;
         Generation : Natural;
         Distance   : Natural;
         From_Tag   : Boolean;
         Taken      : out Boolean)
      is
         Cur : constant Name_Maps.Cursor := Names.Find (Id);
         Val : constant Rev_Name :=
           (Tip_Name   => To_Unbounded_String (Tip_Name),
            Taggerdate => Taggerdate,
            Generation => Generation,
            Distance   => Distance,
            From_Tag   => From_Tag);
      begin
         if not Name_Maps.Has_Element (Cur) then
            Names.Insert (Id, Val);
            Taken := True;
         elsif Is_Better
                 (Name_Maps.Element (Cur), Taggerdate, Generation, Distance,
                  From_Tag)
         then
            Names.Replace_Element (Cur, Val);
            Taken := True;
         else
            Taken := False;
         end if;
      end Offer;

      --  git's name_rev: a depth-first walk from one tip, naming every
      --  commit it can improve on.
      procedure Walk_From
        (Tip        : Version.Objects.Object_Id_Storage;
         Tip_Name   : String;
         Taggerdate : Long_Long_Integer;
         From_Tag   : Boolean)
      is
         Stack : Id_Vectors.Vector;
         Taken : Boolean;
      begin
         Offer (Tip, Tip_Name, Taggerdate, 0, 0, From_Tag, Taken);
         if not Taken then
            return;
         end if;
         Stack.Append (Tip);

         while not Stack.Is_Empty loop
            declare
               Id : constant Version.Objects.Object_Id_Storage :=
                 Stack.Last_Element;
               Name : Rev_Name;
               Pending : Id_Vectors.Vector;
            begin
               Stack.Delete_Last;
               Name := Names.Element (Id);

               declare
                  Obj : constant Version.Objects.Git_Object :=
                    Version.Object_Cache.Read_Object (Repo, Objects, Id);
                  Parents : constant
                    Version.Objects.Object_Id_Vectors.Vector :=
                      Version.Objects.Commit_Parent_Ids (Obj);
               begin
                  for K in Parents.First_Index .. Parents.Last_Index loop
                     declare
                        Number : constant Positive :=
                          Positive (K - Parents.First_Index + 1);
                        Gen : constant Natural :=
                          (if Number > 1 then 0 else Name.Generation + 1);
                        Dist : constant Natural :=
                          (if Number > 1
                           then Name.Distance + Merge_Traversal_Weight
                           else Name.Distance + 1);
                        Sub_Name : constant String :=
                          (if Number > 1 then Parent_Name (Name, Number)
                           else To_String (Name.Tip_Name));
                        Ok : Boolean;
                     begin
                        Offer
                          (Parents.Element (K), Sub_Name, Taggerdate, Gen,
                           Dist, From_Tag, Ok);
                        if Ok then
                           Pending.Append (Parents.Element (K));
                        end if;
                     end;
                  end loop;
               end;

               --  Push in reverse so the first parent is popped first.
               for K in reverse
                 Pending.First_Index .. Pending.Last_Index
               loop
                  Stack.Append (Pending.Element (K));
               end loop;
            exception
               --  A missing or unreadable parent just ends this branch.
               when others =>
                  null;
            end;
         end loop;
      end Walk_From;

      Patterns : Version.Ref_Format.String_Vectors.Vector;

      --  git builds a tip table and sorts it with cmp_by_tag_and_age before
      --  naming anything: tags first, then oldest first. Processing better
      --  tips first stops a worse name from spreading, and it decides exact
      --  ties -- which is why a lightweight tag (carrying its commit's older
      --  date) beats an annotated tag placed on the same commit.
      type Tip_Entry is record
         Commit_Id  : Version.Objects.Object_Id_Storage;
         Tip_Name   : Unbounded_String;
         Taggerdate : Long_Long_Integer := 0;
         From_Tag   : Boolean := False;
      end record;

      function Tip_Less (L, R : Tip_Entry) return Boolean is
        (if L.From_Tag /= R.From_Tag then L.From_Tag
         else L.Taggerdate < R.Taggerdate);

      package Tip_Vectors is new Ada.Containers.Vectors
        (Index_Type => Natural, Element_Type => Tip_Entry);
      package Tip_Sorting is new Tip_Vectors.Generic_Sorting (Tip_Less);

      Tips : Tip_Vectors.Vector;
   begin
      Patterns.Append ("refs/tags/");
      if not Tags_Only then
         Patterns.Append ("refs/heads/");
      end if;

      for Refname of Version.Ref_Format.For_Each_Ref
        (Repo, Patterns, Format => "%(refname)")
      loop
         declare
            Tags_Prefix  : constant String := "refs/tags/";
            Heads_Prefix : constant String := "refs/heads/";
            Is_Tag_Ref : constant Boolean :=
              Refname'Length > Tags_Prefix'Length
              and then Refname (Refname'First
                                .. Refname'First + Tags_Prefix'Length - 1)
                       = Tags_Prefix;
            Short : constant String :=
              (if Is_Tag_Ref
               then "tags/" & Refname (Refname'First + Tags_Prefix'Length
                                       .. Refname'Last)
               elsif Refname'Length > Heads_Prefix'Length
                 and then Refname (Refname'First
                                   .. Refname'First + Heads_Prefix'Length - 1)
                          = Heads_Prefix
               then Refname (Refname'First + Heads_Prefix'Length
                             .. Refname'Last)
               else Refname);
         begin
            declare
               Peeled : constant Version.Objects.Hex_Object_Id :=
                 Version.Revisions.Resolve_Commit (Repo, Refname);
               Raw : constant Version.Objects.Hex_Object_Id :=
                 Version.Refs.Resolve_Ref (Repo, Refname);
               Raw_Obj : constant Version.Objects.Git_Object :=
                 Version.Object_Cache.Read_Object (Repo, Objects, Raw);
               --  An annotated tag names a tag object, so git appends "^0"
               --  to say the name refers to the commit it peels to.
               Deref : constant Boolean :=
                 Version.Objects.Kind (Raw_Obj)
                 = Version.Objects.Tag_Object;
               Stamp : constant Long_Long_Integer :=
                 (if Deref
                  then Tagger_Time (Version.Objects.Content (Raw_Obj))
                  else Version.Objects.Commit_Committer_Time
                         (Version.Object_Cache.Read_Object
                            (Repo, Objects, Peeled)));
            begin
               Tips.Append
                 (Tip_Entry'
                    (Commit_Id  => Peeled,
                     Tip_Name   =>
                       To_Unbounded_String
                         (if Deref then Short & "^0" else Short),
                     Taggerdate => Stamp,
                     From_Tag   => Is_Tag_Ref));
            end;
         exception
            --  A ref that does not resolve to a commit is simply not a tip.
            when others =>
               null;
         end;
      end loop;

      Tip_Sorting.Sort (Tips);

      for Tip of Tips loop
         Walk_From
           (Tip        => Tip.Commit_Id,
            Tip_Name   => To_String (Tip.Tip_Name),
            Taggerdate => Tip.Taggerdate,
            From_Tag   => Tip.From_Tag);
      end loop;


      declare
         Found : constant Name_Maps.Cursor := Names.Find (Target);
      begin
         if not Name_Maps.Has_Element (Found) then
            return Undefined;
         end if;
         return Render (Name_Maps.Element (Found));
      end;
   end Describe_Commit;

end Version.Name_Rev;
