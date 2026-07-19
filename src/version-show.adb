with Ada.IO_Exceptions;
with Ada.Strings.Unbounded;

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
      Commit_Id : Version.Objects.Hex_Object_Id;
      Options   : Version.Diff.Diff_Options := (others => <>);
      No_Patch  : Boolean := False;
      Oneline   : Boolean := False;
      Format    : String := "")
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

      if Oneline then
         --  Max_Count 1: show reports this commit, not the history behind it.
         Append
           (Result,
            Version.Log.Log_Oneline_From_Commit
              (Repo, Commit_Id, Max_Count => 1));
      elsif Format'Length > 0 then
         Append
           (Result,
            Version.Log.Log_Formatted_From_Commit
              (Repo, Commit_Id, Format, Max_Count => 1));
         Append (Result, Character'Val (10));
      else
         Append
           (Result,
            Version.Log.Format_Commit (Repo, Commit_Id, Full_Message => True));
         Append (Result, Character'Val (10));
      end if;

      if No_Patch then
         return To_String (Result);
      end if;

      --  git shows no patch for a merge unless asked with -m/-c/--cc: with
      --  more than one parent there is no single "the" diff, and picking the
      --  first parent silently presents one side's changes as the commit's.
      --  A --stat is still produced, and matches git's combined stat.
      if Natural (Version.Objects.Commit_Parent_Ids (Obj).Length) > 1
        and then not Options.Stat
      then
         return To_String (Result);
      end if;

      if Parent'Length = 0 then
         Append
           (Result, Version.Diff.Diff_Root_Commit (Repo, Commit_Id, Options));
      else
         Append
           (Result,
            Version.Diff.Diff_Commits
              (Repo    => Repo,
               Old_Id  => Version.Objects.To_Object_Id (Parent),
               New_Id  => Commit_Id,
               Options => Options));
      end if;

      return To_String (Result);
   end Show_Commit;

end Version.Show;
