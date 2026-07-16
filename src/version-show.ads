with Version.Diff;
with Version.Objects;
with Version.Repository;

package Version.Show is

   function Resolve_Revision
     (Repo : Version.Repository.Repository_Handle;
      Name : String)
      return Version.Objects.Hex_Object_Id;

   function Show_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Options   : Version.Diff.Diff_Options := (others => <>))
      return String;
   --  Options are forwarded to the embedded diff (e.g. Stat for `show --stat`).

end Version.Show;
