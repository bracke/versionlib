with Ada.Directories;

with Version.Files;
with Version.Repository;
with Version.Reflog;
with Version.Test_Support;

package body Version.Stash_Test_Support is

   LF : constant Character := Character'Val (10);

   function Join (Left, Right : String) return String renames Version.Test_Support.Join;

   function Stash_Ref_Path (Root : String) return String is
   begin
      return Join (Join (Join (Root, ".git"), "refs"), "stash");
   end Stash_Ref_Path;

   function Stash_Log_Path (Root : String) return String is
      Git_Dir : constant String := Join (Root, ".git");
   begin
      if Ada.Directories.Exists (Version.Files.To_Native_Path (Git_Dir)) then
         declare
            Repo : constant Version.Repository.Repository_Handle :=
              Version.Repository.Open_Git_Dir
                (Version.Repository.Resolve_Git_Dir (Root));
         begin
            return Version.Reflog.Path (Repo, "refs/stash");
         end;
      end if;

      return Join (Join (Join (Join (Root, ".git"), "logs"), "refs"), "stash");
   end Stash_Log_Path;

   function Stash_Reflog_Line
     (Old_Id  : String;
      New_Id  : String;
      Message : String)
      return String
   is
   begin
      return
        Old_Id & " " & New_Id
        & " Version <version@example.invalid> 0 +0000"
        & Character'Val (9)
        & Message;
   end Stash_Reflog_Line;

   function Broken_Reflog_Chain
     (First_Id  : String;
      Second_Id : String;
      Bad_Old   : String := Bad_Old_Id)
      return String
   is
   begin
      return
        Stash_Reflog_Line (Zero_Id, First_Id, "first") & LF
        & Stash_Reflog_Line (Bad_Old, Second_Id, "second") & LF;
   end Broken_Reflog_Chain;

   procedure Write_Stash_Storage
     (Root    : String;
      New_Id  : String;
      Message : String)
   is
      Ref_Path : constant String := Stash_Ref_Path (Root);
      Log_Path : constant String := Stash_Log_Path (Root);
   begin
      Version.Files.Create_Parent_Directories (Ref_Path);
      Version.Files.Create_Parent_Directories (Log_Path);
      Version.Test_Support.Write_Text_File (Ref_Path, New_Id & LF);
      Version.Test_Support.Write_Text_File
        (Log_Path, Stash_Reflog_Line (Zero_Id, New_Id, Message) & LF);
   end Write_Stash_Storage;

end Version.Stash_Test_Support;
