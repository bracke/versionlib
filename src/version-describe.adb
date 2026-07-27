with Ada.Containers.Indefinite_Hashed_Sets;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Hash;
with Ada.Strings.Unbounded;

with Version.History;
with Version.Refs;
with Version.Revisions;
with Version.Tags;

package body Version.Describe is
   use Version.Objects;

   use Ada.Strings.Unbounded;

   LF : constant Character := Character'Val (10);

   package Id_Sets is new Ada.Containers.Indefinite_Hashed_Sets
     (Element_Type        => String,
      Hash                => Ada.Strings.Hash,
      Equivalent_Elements => "=");

   --  git describe's distance: the number of commits `git log <tag>..<commit>`
   --  would show -- every commit reachable from Commit but not from Tag. A
   --  full all-parents walk, so merge commits count correctly (the old code
   --  reused rebase's linear replay, which rejects merges outright).
   function Distance
     (Repo : Version.Repository.Repository_Handle;
      Tag_Commit, Commit : Version.Objects.Hex_Object_Id)
      return Natural
   is
      Excluded : Id_Sets.Set;   --  Tag_Commit and all its ancestors
      Counted  : Id_Sets.Set;   --  Commit's ancestors that are not excluded
      Stack    : Version.History.Commit_Id_Vectors.Vector;

      procedure Push (Id : Version.Objects.Hex_Object_Id) is
      begin
         Stack.Append (Id);
      end Push;
   begin
      Push (Tag_Commit);
      while not Stack.Is_Empty loop
         declare
            C   : constant Version.Objects.Hex_Object_Id :=
              Stack.Last_Element;
            Hex : constant String := To_String (C);
         begin
            Stack.Delete_Last;
            if not Excluded.Contains (Hex) then
               Excluded.Include (Hex);
               for P of Version.History.Parent_Commits (Repo, C) loop
                  Push (P);
               end loop;
            end if;
         end;
      end loop;

      Push (Commit);
      while not Stack.Is_Empty loop
         declare
            C   : constant Version.Objects.Hex_Object_Id :=
              Stack.Last_Element;
            Hex : constant String := To_String (C);
         begin
            Stack.Delete_Last;
            if not Excluded.Contains (Hex) and then not Counted.Contains (Hex)
            then
               Counted.Include (Hex);
               for P of Version.History.Parent_Commits (Repo, C) loop
                  Push (P);
               end loop;
            end if;
         end;
      end loop;

      return Natural (Counted.Length);
   end Distance;

   function Glob (Text, Pattern : String) return Boolean is
      function M (T, P : Natural) return Boolean is
      begin
         if P > Pattern'Last then
            return T > Text'Last;
         end if;
         case Pattern (P) is
            when '*' =>
               for K in T - 1 .. Text'Last loop
                  if M (K + 1, P + 1) then
                     return True;
                  end if;
               end loop;
               return False;
            when '?' =>
               return T <= Text'Last and then M (T + 1, P + 1);
            when others =>
               return T <= Text'Last and then Text (T) = Pattern (P)
                 and then M (T + 1, P + 1);
         end case;
      end M;
   begin
      return M (Text'First, Pattern'First);
   end Glob;

   function Describe
     (Repo     : Version.Repository.Repository_Handle;
      Commit   : Version.Objects.Hex_Object_Id;
      All_Tags : Boolean := False;
      Long     : Boolean := False;
      Abbrev   : Natural := 7;
      Pattern  : String  := "";
      Exclude  : String  := "")
      return String
   is
      Tags      : constant Version.Tags.Tag_Name_Vectors.Vector :=
        Version.Tags.List_Tags;
      Best_Tag   : Unbounded_String;
      Best_Dist       : Natural := Natural'Last;
      Best_Exact      : Boolean := False;
      Best_Annotated  : Boolean := False;

      --  Track reachability separately so the failure message can distinguish
      --  "no tags at all" from "only lightweight tags" (git's --tags hint).
      Any_Reachable   : Boolean := False;
      Light_Reachable : Boolean := False;

      --  A tag is annotated when refs/tags/<name> points at a tag object
      --  rather than directly at the commit.
      --  The tagger timestamp of an annotated tag, 0 for anything else. git
      --  breaks a distance tie by tag date, newest first, so two tags on the
      --  same commit do not resolve alphabetically -- which is how a release
      --  tag could lose to an older one that merely sorts earlier.
      function Tag_Time (Tag_Name : String) return Long_Long_Integer is
         Ref_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Refs.Resolve_Ref (Repo, "refs/tags/" & Tag_Name);
         Obj    : constant Version.Objects.Git_Object :=
           Version.Objects.Read_Object (Repo, Ref_Id);
      begin
         if Version.Objects.Kind (Obj) /= Version.Objects.Tag_Object then
            return 0;
         end if;

         declare
            Content : constant String := Version.Objects.Content (Obj);
            Start   : constant Natural :=
              Ada.Strings.Fixed.Index (Content, "tagger ");
            Stop    : Natural;
            Last_Sp : Natural := 0;
            Prev_Sp : Natural := 0;
         begin
            if Start = 0 then
               return 0;
            end if;

            Stop := Ada.Strings.Fixed.Index
              (Content (Start .. Content'Last), "" & Character'Val (10));
            if Stop = 0 then
               Stop := Content'Last;
            else
               Stop := Stop - 1;
            end if;

            --  "tagger Name <mail> <unix-seconds> <zone>": the timestamp is
            --  the second-to-last whitespace-separated token.
            for I in Start .. Stop loop
               if Content (I) = ' ' then
                  Prev_Sp := Last_Sp;
                  Last_Sp := I;
               end if;
            end loop;

            if Prev_Sp = 0 or else Last_Sp <= Prev_Sp + 1 then
               return 0;
            end if;

            return Long_Long_Integer'Value
              (Content (Prev_Sp + 1 .. Last_Sp - 1));
         end;
      exception
         when others =>
            return 0;
      end Tag_Time;

      Best_Time : Long_Long_Integer := Long_Long_Integer'First;

      function Is_Annotated (Tag_Name : String) return Boolean is
         Ref_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Refs.Resolve_Ref (Repo, "refs/tags/" & Tag_Name);
      begin
         return Version.Objects.Kind
                  (Version.Objects.Read_Object (Repo, Ref_Id))
                = Version.Objects.Tag_Object;
      end Is_Annotated;
   begin
      for Tag of Tags loop
         declare
            Name       : constant String := To_String (Tag);
            --  --match: a tag whose name does not match the glob is not a
            --  candidate at all, so it cannot become the best. --exclude drops
            --  a tag whose name matches the exclude glob.
            Matches    : constant Boolean :=
              (Pattern'Length = 0 or else Glob (Name, Pattern))
              and then (Exclude'Length = 0 or else not Glob (Name, Exclude));
            Annotated  : constant Boolean :=
              Matches and then Is_Annotated (Name);
            Tag_Commit : constant Version.Objects.Hex_Object_Id :=
              Version.Revisions.Resolve_Commit (Repo, Name);
            Exact      : constant Boolean := Matches and then Tag_Commit = Commit;
            Reachable  : constant Boolean :=
              Matches and then
                (Exact
              or else Version.History.Is_Ancestor
                        (Repo,
                         Base_Id    => Tag_Commit,
                         Derived_Id => Commit));
         begin
            if Reachable then
               Any_Reachable := True;
               if not Annotated then
                  Light_Reachable := True;
               end if;

               if All_Tags or else Annotated then
                  declare
                     Dist : constant Natural :=
                       (if Exact then 0
                        else Distance (Repo, Tag_Commit, Commit));
                  begin
                     --  Nearest tag wins; at equal distance git prefers an
                     --  annotated tag over a lightweight one, and between two
                     --  of the same kind the more recently tagged one.
                     declare
                        This_Time : constant Long_Long_Integer :=
                          Tag_Time (Name);
                        Better : constant Boolean :=
                          Dist < Best_Dist
                          or else (Dist = Best_Dist
                                   and then Annotated
                                   and then not Best_Annotated)
                          or else (Dist = Best_Dist
                                   and then Annotated = Best_Annotated
                                   and then This_Time > Best_Time);
                     begin
                        if Better then
                           Best_Dist      := Dist;
                           Best_Tag       := Tag;
                           Best_Exact     := Exact;
                           Best_Annotated := Annotated;
                           Best_Time      := This_Time;
                        end if;
                     end;
                  end;
               end if;
            end if;
         end;
      end loop;

      if Length (Best_Tag) > 0 then
         declare
            Hex : constant String := To_String (Commit);
            --  git clamps --abbrev to at least 4 when it is used, but 0 turns
            --  the suffix off entirely.
            N   : constant Natural :=
              (if Abbrev = 0 then 0
               else Natural'Min (Natural'Max (Abbrev, 4), Hex'Length));
            Short : constant String :=
              (if N = 0 then "" else "-g" & Hex (Hex'First .. Hex'First + N - 1));
         begin
            --  --long keeps the count and short id even on an exact match.
            if Best_Exact and then not Long then
               return To_String (Best_Tag);
            end if;
            return To_String (Best_Tag) & "-"
              & Ada.Strings.Fixed.Trim
                  (Natural'Image (Best_Dist), Ada.Strings.Left)
              & Short;
         end;
      end if;

      --  No eligible tag matched — reproduce git's diagnostics.
      if not Any_Reachable then
         raise Ada.IO_Exceptions.Data_Error with
           "No names found, cannot describe anything.";
      elsif not All_Tags and then Light_Reachable then
         raise Ada.IO_Exceptions.Data_Error with
           "No annotated tags can describe '" & To_String (Commit) & "'." & LF
           & "However, there were unannotated tags: try --tags.";
      else
         raise Ada.IO_Exceptions.Data_Error with
           "No tags can describe '" & To_String (Commit) & "'.";
      end if;
   end Describe;

   function Describe_By_Any_Ref
     (Repo    : Version.Repository.Repository_Handle;
      Commit  : Version.Objects.Hex_Object_Id;
      Long    : Boolean := False;
      Abbrev  : Natural := 7;
      Pattern : String  := "";
      Exclude : String  := "")
      return String
   is
      --  Every ref, as "<namespace>/<name>" the way --all reports it. Only
      --  the ones reachable from Commit are candidates; the nearest wins,
      --  exactly as for tags.
      Best_Name : Unbounded_String;
      Best_Dist : Natural := Natural'Last;
      Best_Exact : Boolean := False;
      Best_Annotated : Boolean := False;
      Best_Time  : Long_Long_Integer := Long_Long_Integer'First;
      Any        : Boolean := False;

      --  The tagger timestamp of the annotated tag Ref points at (0 otherwise),
      --  so two tags on one commit break the tie by date, newest first.
      function Ref_Tag_Time (Ref : String) return Long_Long_Integer is
         Obj : constant Version.Objects.Git_Object :=
           Version.Objects.Read_Object
             (Repo, Version.Refs.Resolve_Ref (Repo, Ref));
      begin
         if Version.Objects.Kind (Obj) /= Version.Objects.Tag_Object then
            return 0;
         end if;
         declare
            Content : constant String := Version.Objects.Content (Obj);
            Start   : constant Natural :=
              Ada.Strings.Fixed.Index (Content, "tagger ");
            Stop    : Natural;
            Last_Sp : Natural := 0;
            Prev_Sp : Natural := 0;
         begin
            if Start = 0 then
               return 0;
            end if;
            Stop := Ada.Strings.Fixed.Index
              (Content (Start .. Content'Last), "" & Character'Val (10));
            Stop := (if Stop = 0 then Content'Last else Stop - 1);
            for I in Start .. Stop loop
               if Content (I) = ' ' then
                  Prev_Sp := Last_Sp;
                  Last_Sp := I;
               end if;
            end loop;
            if Prev_Sp = 0 or else Last_Sp <= Prev_Sp + 1 then
               return 0;
            end if;
            return Long_Long_Integer'Value
              (Content (Prev_Sp + 1 .. Last_Sp - 1));
         end;
      exception
         when others =>
            return 0;
      end Ref_Tag_Time;

      procedure Consider (Display, Ref : String; Annotated : Boolean) is
      begin
         if Pattern'Length > 0
           and then not Glob (Display, Pattern)
         then
            return;
         end if;
         if Exclude'Length > 0 and then Glob (Display, Exclude) then
            return;
         end if;

         declare
            Ref_Commit : constant Version.Objects.Hex_Object_Id :=
              Version.Revisions.Resolve_Commit (Repo, Ref);
            Exact : constant Boolean := Ref_Commit = Commit;
            Reachable : constant Boolean :=
              Exact
              or else Version.History.Is_Ancestor
                        (Repo, Base_Id => Ref_Commit, Derived_Id => Commit);
         begin
            if Reachable then
               Any := True;
               declare
                  Dist : constant Natural :=
                    (if Exact then 0
                     else Distance (Repo, Ref_Commit, Commit));
                  This_Time : constant Long_Long_Integer :=
                    (if Annotated then Ref_Tag_Time (Ref) else 0);
               begin
                  --  Nearer wins; on a tie git prefers an annotated tag, then
                  --  the newest tagger date.
                  if Dist < Best_Dist
                    or else (Dist = Best_Dist
                             and then Annotated and then not Best_Annotated)
                    or else (Dist = Best_Dist
                             and then Annotated = Best_Annotated
                             and then This_Time > Best_Time)
                  then
                     Best_Dist := Dist;
                     Best_Name := To_Unbounded_String (Display);
                     Best_Exact := Exact;
                     Best_Annotated := Annotated;
                     Best_Time := This_Time;
                  end if;
               end;
            end if;
         exception
            when others =>
               null;
         end;
      end Consider;
   begin
      for T of Version.Tags.List_Tags loop
         declare
            Ref : constant String := "refs/tags/" & To_String (T);
            Annot : constant Boolean :=
              Version.Objects.Kind
                (Version.Objects.Read_Object
                   (Repo, Version.Refs.Resolve_Ref (Repo, Ref)))
              = Version.Objects.Tag_Object;
         begin
            Consider ("tags/" & To_String (T), Ref, Annot);
         end;
      end loop;
      for B of Version.Refs.List_Branches (Repo) loop
         Consider
           ("heads/" & To_String (B), "refs/heads/" & To_String (B), False);
      end loop;

      if Length (Best_Name) > 0 then
         declare
            Hex : constant String := To_String (Commit);
            N   : constant Natural :=
              (if Abbrev = 0 then 0
               else Natural'Min (Natural'Max (Abbrev, 4), Hex'Length));
            Short : constant String :=
              (if N = 0 then "" else "-g" & Hex (Hex'First .. Hex'First + N - 1));
         begin
            if Best_Exact and then not Long then
               return To_String (Best_Name);
            end if;
            return To_String (Best_Name) & "-"
              & Ada.Strings.Fixed.Trim
                  (Natural'Image (Best_Dist), Ada.Strings.Left)
              & Short;
         end;
      end if;

      raise Ada.IO_Exceptions.Data_Error with
        "No names found, cannot describe anything.";
   end Describe_By_Any_Ref;

end Version.Describe;
