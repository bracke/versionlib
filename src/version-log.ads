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
      Show_Signature : Boolean := False;
      Max_Count      : Natural := 0;
      Stat           : Boolean := False;
      Patch          : Boolean := False;
      Context        : Natural := 3)
      return String;
   --  Patch appends git's `-p`/`--patch` diff (against the first parent, or the
   --  empty tree for a root commit) after each commit; Context is its `-U<n>`.
   --  Stat appends git's `--stat` diffstat (against the first parent, or the
   --  empty tree for a root commit) after each commit.
   --  Show_Signature interleaves gpg's verification lines (as
   --  `log --show-signature`) after each commit header for signed commits.
   --  Max_Count limits the number of commits shown (git's -<n>/-n <count>);
   --  0 means unlimited.

   function Log_Oneline_From_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Max_Count : Natural := 0)
      return String;

   function Log_Head
     (Repo           : Version.Repository.Repository_Handle;
      Show_Signature : Boolean := False;
      Max_Count      : Natural := 0;
      Stat           : Boolean := False;
      Patch          : Boolean := False;
      Context        : Natural := 3)
      return String;

   function Log_Oneline_Head
     (Repo      : Version.Repository.Repository_Handle;
      Max_Count : Natural := 0)
      return String;

   function Log_Formatted_From_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Format    : String;
      Terminate_Records : Boolean := True;
      Max_Count : Natural := 0)
      return String;
   --  Walk first-parent history from Commit_Id, expanding each commit through
   --  Version.Pretty_Format with Format. Terminate_Records = True appends a
   --  newline after every record (git's `--format`/`tformat:`); False joins
   --  records with a single newline and omits the trailing one (git's
   --  `--pretty=format:`).

end Version.Log;
