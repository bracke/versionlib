with Version.History;
with Version.Objects;
with Version.Repository;

package Version.Log is

   function Format_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Full_Message : Boolean := False)
      return String;

   function Log_List_Text
     (Repo           : Version.Repository.Repository_Handle;
      Commits        : Version.History.Commit_Id_Vectors.Vector;
      Show_Signature : Boolean := False;
      Stat           : Boolean := False;
      Patch          : Boolean := False;
      Name_Only      : Boolean := False;
      Name_Status    : Boolean := False;
      Numstat        : Boolean := False;
      Shortstat      : Boolean := False;
      Raw            : Boolean := False;
      Context        : Natural := 3;
      Oneline        : Boolean := False;
      Date_Mode      : String := "") return String;
   --  Date_Mode is `--date=<mode>` for the "Date:" header (iso/short/raw/...).
   --  Oneline replaces each commit's header with git's oneline form and runs
   --  the file changes straight after it (no separating blank), as
   --  `log --oneline --name-only`/`--numstat`/`--raw`/... do.

   type Decorate_Mode is (No_Decorate, Short_Decorate, Full_Decorate);

   function Log_Oneline_List_Text
     (Repo         : Version.Repository.Repository_Handle;
      Commits      : Version.History.Commit_Id_Vectors.Vector;
      With_Parents : Boolean := False;
      Decorate     : Decorate_Mode := No_Decorate) return String;
   --  With_Parents adds git's `--parents`: the abbreviated parent ids after
   --  each commit id. Decorate adds git's `--decorate` ref names in parens
   --  (Short_Decorate: "main"/"tag: v2"; Full_Decorate: the full refnames),
   --  with the current branch shown as "HEAD -> <branch>".

   function Log_Formatted_List_Text
     (Repo    : Version.Repository.Repository_Handle;
      Commits : Version.History.Commit_Id_Vectors.Vector;
      Format  : String;
      Terminate_Records : Boolean := True;
      Date_Mode : String := "") return String;
   --  Render an already-selected list of commits. The caller does the
   --  revision walk, so ranges, exclusions, path limits and ordering are
   --  decided once and shared with rev-list rather than re-derived here.

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
      Max_Count : Natural := 0;
      Date_Mode : String := "")
      return String;
   --  Walk first-parent history from Commit_Id, expanding each commit through
   --  Version.Pretty_Format with Format. Terminate_Records = True appends a
   --  newline after every record (git's `--format`/`tformat:`); False joins
   --  records with a single newline and omits the trailing one (git's
   --  `--pretty=format:`).

end Version.Log;
