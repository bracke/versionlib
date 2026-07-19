with Ada.Strings.Unbounded;

with Version.History;
with Version.Patch_Id;

package body Version.Cherry is

   use Ada.Strings.Unbounded;

   package Id_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Unbounded_String);

   --  The commits reachable from One but not from Other, oldest first --
   --  git's `rev-list --reverse Other..One`, which is exactly what `cherry`
   --  compares.
   --
   --  This deliberately does not go through the rebase replay walk. That walk
   --  follows first parents and refuses a root or a merge commit, so `cherry`
   --  used to fail outright with "root rebases not supported" on any history
   --  whose side reached a root before the merge base -- which a `replace
   --  --graft` can produce, and a repository with unrelated histories always
   --  does. Listing commits has none of those constraints.
   function Only_In
     (Repo  : Version.Repository.Repository_Handle;
      One   : Version.Objects.Hex_Object_Id;
      Other : Version.Objects.Hex_Object_Id)
      return Version.History.Commit_Id_Vectors.Vector
   is
      Include : Version.History.Commit_Id_Vectors.Vector;
      Exclude : Version.History.Commit_Id_Vectors.Vector;
      Options : Version.History.Rev_List_Options;
   begin
      Include.Append (One);
      Exclude.Append (Other);
      Options.Oldest_First := True;
      return Version.History.Rev_List (Repo, Include, Exclude, Options);
   end Only_In;

   function Status
     (Repo     : Version.Repository.Repository_Handle;
      Upstream : Version.Objects.Hex_Object_Id;
      Head     : Version.Objects.Hex_Object_Id)
      return Cherry_Vectors.Vector
   is
      Up_Only   : constant Version.History.Commit_Id_Vectors.Vector :=
        Only_In (Repo, Upstream, Head);
      Head_Only : constant Version.History.Commit_Id_Vectors.Vector :=
        Only_In (Repo, Head, Upstream);

      Up_Pids : Id_Vectors.Vector;
      Result  : Cherry_Vectors.Vector;

      function Known (P : String) return Boolean is
      begin
         for U of Up_Pids loop
            if To_String (U) = P then
               return True;
            end if;
         end loop;
         return False;
      end Known;
   begin
      for C of Up_Only loop
         Up_Pids.Append
           (To_Unbounded_String (Version.Patch_Id.Of_Commit (Repo, C)));
      end loop;

      for C of Head_Only loop
         Result.Append
           (Cherry_Entry'
              (Id                  => C,
               Equivalent_Upstream =>
                 Known (Version.Patch_Id.Of_Commit (Repo, C))));
      end loop;

      return Result;
   end Status;

end Version.Cherry;
