with Ada.Directories;
with GNAT.OS_Lib;

with Version.Test_Support;

package body Version.Git_Fixtures is

   procedure Run
     (Dir     : String;
      Command : String)
   is
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Status  : Integer;

      Args : GNAT.OS_Lib.Argument_List :=
        [1 => new String'("-c"),
         2 => new String'(Command)];
   begin
      Ada.Directories.Set_Directory (Dir);

      Status :=
        GNAT.OS_Lib.Spawn
          (Program_Name => "/bin/sh",
           Args         => Args);

      Ada.Directories.Set_Directory (Old_Dir);

      GNAT.OS_Lib.Free (Args (1));
      GNAT.OS_Lib.Free (Args (2));

      if Status /= 0 then
         raise Program_Error with
           "command failed: " & Command;
      end if;

   exception
      when others =>
         if Ada.Directories.Current_Directory /= Old_Dir then
            Ada.Directories.Set_Directory (Old_Dir);
         end if;

         GNAT.OS_Lib.Free (Args (1));
         GNAT.OS_Lib.Free (Args (2));

         raise;
   end Run;

   procedure Init_Repo_With_One_Commit
     (Root : String)
   is
   begin
      Run (Root, "git init");
      Run (Root, "git config user.email test@example.com");
      Run (Root, "git config user.name Test");
      Run (Root, "git config gc.auto 0");

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "a.txt"),
         "hello" & Character'Val (10));

      Run (Root, "git add a.txt");
      Run (Root, "git commit -m initial");
   end Init_Repo_With_One_Commit;

   procedure Init_Repo_With_Similar_Files
   (Root : String)
   is
   begin
      Run (Root, "git init");
      Run (Root, "git config user.email test@example.com");
      Run (Root, "git config user.name Test");
      Run (Root, "git config gc.auto 0");

      Version.Test_Support.Write_Text_File
      (Version.Test_Support.Join (Root, "a.txt"),
         "line 1" & Character'Val (10)
         & "line 2" & Character'Val (10)
         & "line 3" & Character'Val (10)
         & "line 4" & Character'Val (10));

      Version.Test_Support.Write_Text_File
      (Version.Test_Support.Join (Root, "b.txt"),
         "line 1" & Character'Val (10)
         & "line 2 changed" & Character'Val (10)
         & "line 3" & Character'Val (10)
         & "line 4" & Character'Val (10));

      Version.Test_Support.Write_Text_File
      (Version.Test_Support.Join (Root, "c.txt"),
         "line 1" & Character'Val (10)
         & "line 2 changed again" & Character'Val (10)
         & "line 3" & Character'Val (10)
         & "line 4" & Character'Val (10));

      Run (Root, "git add a.txt b.txt c.txt");
      Run (Root, "git commit -m similar-files");
   end Init_Repo_With_Similar_Files;

end Version.Git_Fixtures;