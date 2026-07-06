with Ada.IO_Exceptions;
with Ada.Strings.Unbounded;

with Version.Diff;
with Version.Log;
with Version.Objects; use Version.Objects;
with Version.Revisions;

package body Version.Show is

   use Ada.Strings.Unbounded;

   function Resolve_Revision
     (Repo : Version.Repository.Repository_Handle;
      Name : String)
      return Version.Objects.Hex_Object_Id
   is
   begin
      return Version.Revisions.Resolve_Commit (Repo, Name);
   end Resolve_Revision;

   function Show_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id)
      return String
   is
      Obj      : constant Version.Objects.Git_Object :=
        Version.Objects.Read_Object (Repo, Commit_Id);
      Parent   : constant String := Version.Objects.Commit_Parent_Id (Obj);
      Result   : Unbounded_String;
   begin
      if Version.Objects.Kind (Obj) /= Version.Objects.Commit_Object then
         raise Ada.IO_Exceptions.Data_Error with "object is not a commit: " & To_String (Commit_Id);
      end if;

      Append (Result, Version.Log.Format_Commit (Repo, Commit_Id, Full_Message => True));
      Append (Result, Character'Val (10));

      if Parent'Length = 0 then
         Append (Result, Version.Diff.Diff_Root_Commit (Repo, Commit_Id));
      else
         Append
           (Result,
            Version.Diff.Diff_Commits
              (Repo   => Repo,
               Old_Id => Version.Objects.To_Object_Id (Parent),
               New_Id => Commit_Id));
      end if;

      return To_String (Result);
   end Show_Commit;

end Version.Show;
