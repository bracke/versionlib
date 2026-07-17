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

   function Describe
     (Repo     : Version.Repository.Repository_Handle;
      Commit   : Version.Objects.Hex_Object_Id;
      All_Tags : Boolean := False)
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
            Annotated  : constant Boolean := Is_Annotated (Name);
            Tag_Commit : constant Version.Objects.Hex_Object_Id :=
              Version.Revisions.Resolve_Commit (Repo, Name);
            Exact      : constant Boolean := Tag_Commit = Commit;
            Reachable  : constant Boolean :=
              Exact
              or else Version.History.Is_Ancestor
                        (Repo,
                         Base_Id    => Tag_Commit,
                         Derived_Id => Commit);
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
                     --  annotated tag over a lightweight one.
                     if Dist < Best_Dist
                       or else (Dist = Best_Dist
                                and then Annotated and then not Best_Annotated)
                     then
                        Best_Dist      := Dist;
                        Best_Tag       := Tag;
                        Best_Exact     := Exact;
                        Best_Annotated := Annotated;
                     end if;
                  end;
               end if;
            end if;
         end;
      end loop;

      if Length (Best_Tag) > 0 then
         if Best_Exact then
            return To_String (Best_Tag);
         end if;
         return To_String (Best_Tag) & "-"
           & Ada.Strings.Fixed.Trim
               (Natural'Image (Best_Dist), Ada.Strings.Left)
           & "-g"
           & To_String (Commit)
               (To_String (Commit)'First .. To_String (Commit)'First + 6);
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

end Version.Describe;
