with Ada.IO_Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Version.History;
with Version.Rebase;
with Version.Revisions;
with Version.Tags;

package body Version.Describe is
   use Version.Objects;

   use Ada.Strings.Unbounded;

   function Describe
     (Repo   : Version.Repository.Repository_Handle;
      Commit : Version.Objects.Hex_Object_Id)
      return String
   is
      Tags      : constant Version.Tags.Tag_Name_Vectors.Vector :=
        Version.Tags.List_Tags;
      Best_Tag  : Unbounded_String;
      Best_Dist : Natural := Natural'Last;
   begin
      for Tag of Tags loop
         declare
            Tag_Commit : constant Version.Objects.Hex_Object_Id :=
              Version.Revisions.Resolve_Commit (Repo, To_String (Tag));
         begin
            if Tag_Commit = Commit then
               return To_String (Tag);  --  exact match
            elsif Version.History.Is_Ancestor
                    (Repo,
                     Base_Id    => Tag_Commit,
                     Derived_Id => Commit)
            then
               declare
                  Dist : constant Natural :=
                    Natural
                      (Version.Rebase.Commits_To_Replay
                         (Repo, Commit, Tag_Commit).Length);
               begin
                  if Dist < Best_Dist then
                     Best_Dist := Dist;
                     Best_Tag := Tag;
                  end if;
               end;
            end if;
         end;
      end loop;

      if Length (Best_Tag) = 0 then
         raise Ada.IO_Exceptions.Data_Error with
           "no tag describes " & To_String (Commit);
      end if;

      return To_String (Best_Tag) & "-"
        & Ada.Strings.Fixed.Trim (Natural'Image (Best_Dist), Ada.Strings.Left)
        & "-g" & To_String (Commit) (To_String (Commit)'First .. To_String (Commit)'First + 6);
   end Describe;

end Version.Describe;
