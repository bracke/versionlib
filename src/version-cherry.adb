with Ada.Strings.Unbounded;

with Version.Patch_Id;
with Version.Rebase;
with Version.Rebase_State;

package body Version.Cherry is

   use Ada.Strings.Unbounded;

   package Id_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Unbounded_String);

   function Status
     (Repo     : Version.Repository.Repository_Handle;
      Upstream : Version.Objects.Hex_Object_Id;
      Head     : Version.Objects.Hex_Object_Id)
      return Cherry_Vectors.Vector
   is
      Up_Only : constant Version.Rebase_State.Commit_Vectors.Vector :=
        Version.Rebase.Commits_To_Replay (Repo, Upstream, Head);
      Head_Only : constant Version.Rebase_State.Commit_Vectors.Vector :=
        Version.Rebase.Commits_To_Replay (Repo, Head, Upstream);

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
