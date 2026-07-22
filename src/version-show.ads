with Version.Diff;
with Version.Objects;
with Version.Repository;

package Version.Show is

   function Resolve_Revision
     (Repo : Version.Repository.Repository_Handle;
      Name : String)
      return Version.Objects.Hex_Object_Id;

   function Show_Commit
     (Repo         : Version.Repository.Repository_Handle;
      Commit_Id    : Version.Objects.Hex_Object_Id;
      Options      : Version.Diff.Diff_Options := (others => <>);
      No_Patch     : Boolean := False;
      Oneline      : Boolean := False;
      Format       : String := "";
      Format_Oneline : Boolean := False)
      return String;
   --  Format_Oneline marks a `--pretty=oneline` format so the header runs
   --  straight into the diff (no separating blank line), as git does.
   --  Options are forwarded to the embedded diff (e.g. Stat for `show --stat`).
   --  No_Patch is git's -s/--no-patch: the header alone. Oneline and Format
   --  select the header's shape, as `show --oneline` and `show --format=<f>`
   --  do; both still print the diff unless No_Patch says otherwise.

end Version.Show;
