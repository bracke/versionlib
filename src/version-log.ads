with Version.Objects;
with Version.Repository;

package Version.Log is

   function Format_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Full_Message : Boolean := False)
      return String;

   function Log_From_Commit
     (Repo           : Version.Repository.Repository_Handle;
      Commit_Id      : Version.Objects.Hex_Object_Id;
      Show_Signature : Boolean := False)
      return String;
   --  Show_Signature interleaves gpg's verification lines (as
   --  `log --show-signature`) after each commit header for signed commits.

   function Log_Oneline_From_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id)
      return String;

   function Log_Head
     (Repo           : Version.Repository.Repository_Handle;
      Show_Signature : Boolean := False)
      return String;

   function Log_Oneline_Head
     (Repo : Version.Repository.Repository_Handle)
      return String;

end Version.Log;
