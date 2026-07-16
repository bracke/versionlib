with Ada.IO_Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Version.History;
with Version.Rebase;
with Version.Refs;
with Version.Revisions;
with Version.Tags;

package body Version.Describe is
   use Version.Objects;

   use Ada.Strings.Unbounded;

   LF : constant Character := Character'Val (10);

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
                        else Natural
                               (Version.Rebase.Commits_To_Replay
                                  (Repo, Commit, Tag_Commit).Length));
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
