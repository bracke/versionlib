with GNAT.OS_Lib;

with Version.Platform;
with Ada.Strings.Unbounded;

with Version.Files;
with Version.Objects;
with Version.Repository;
with Version.Staging;
with Version.Write;

with Project_Tools.Files;
with Project_Tools.Test_Fixtures;

--  Thin adapter over the shared project_tools test-fixture helpers, keeping the
--  Version.Test_Support API the test suites already use. The fixture logic
--  lives once in Project_Tools.Test_Fixtures / Project_Tools.Files.
package body Version.Test_Support is

   --  Forward slashes throughout: every fixture interpolates this root into
   --  a shell command, and on Windows the native spelling arrives as
   --  C:\Users\... whose backslashes sh reads as escapes -- the path came out
   --  as C:UsersRUNNER~1AppData... and nothing could be written to it. Windows
   --  itself accepts either separator.
   function Fresh_Temp_Dir (Name : String) return String is
      --  Canonical first: on Windows %TEMP% is the 8.3 short spelling, while
      --  git and the CLI print the long one, so a fixture path built from it
      --  never matched the paths in the output it was compared against.
      Dir : String :=
        Version.Platform.Canonical_Path
          (Project_Tools.Test_Fixtures.Fresh_Temp_Dir (Name));
   begin
      for C of Dir loop
         if C = '\' then
            C := '/';
         end if;
      end loop;
      return Dir;
   end Fresh_Temp_Dir;

   procedure Cleanup (Path : String) is
   begin
      Project_Tools.Test_Fixtures.Cleanup (Path);
   end Cleanup;

   procedure Make_Directory (Path : String) is
   begin
      Project_Tools.Test_Fixtures.Make_Directory (Path);
   end Make_Directory;

   procedure Write_Text_File (Path : String; Content : String) is
   begin
      --  Byte for byte: a fixture writes the content it means, and a host
      --  that translates would otherwise turn `#!/bin/sh` into `#!/bin/sh\r`
      --  -- an interpreter no shell can find -- and a `.gitignore` or a
      --  patch into something git never wrote.
      Version.Files.Write_Binary_File (Path, Content);
   end Write_Text_File;

   function Read_Text_File (Path : String) return String is
   begin
      return Project_Tools.Test_Fixtures.Read_Text_File (Path);
   end Read_Text_File;

   function Join (Left : String; Right : String) return String is
   begin
      return Project_Tools.Files.Join (Left, Right);
   end Join;

   procedure Stage_Resolved_File
     (Root : String;
      Path : String)
   is
      use Ada.Strings.Unbounded;

      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
      Blob : constant Version.Objects.Hex_Object_Id :=
        Version.Write.Write_Blob
          (Repo, Version.Files.Read_Binary_File (Join (Root, Path)));
      Kept : Version.Staging.Index_Entry_Vectors.Vector;
   begin
      for E of Version.Staging.Load (Repo) loop
         if To_String (E.Path) /= Path then
            Kept.Append (E);
         end if;
      end loop;

      Kept.Append
        (Version.Staging.Index_Entry'
           (Path  => To_Unbounded_String (Path),
            Id    => Blob,
            Mode  => To_Unbounded_String ("100644"),
            Stage => 0, Skip_Worktree => False, Assume_Valid => False, Intent_To_Add => False));
      Version.Staging.Sort_By_Path (Kept);
      Version.Staging.Write (Repo => Repo, Entries => Kept);
   end Stage_Resolved_File;

   function Shell_Program return String is
      use type GNAT.OS_Lib.String_Access;
      Found : GNAT.OS_Lib.String_Access :=
        GNAT.OS_Lib.Locate_Exec_On_Path ("sh");
   begin
      if Found = null then
         return "/bin/sh";
      end if;
      declare
         Path : constant String := Found.all;
      begin
         GNAT.OS_Lib.Free (Found);
         return Path;
      end;
   end Shell_Program;

   procedure Accept_With_Timeout
     (Server  : GNAT.Sockets.Socket_Type;
      Client  : out GNAT.Sockets.Socket_Type;
      Peer    : out GNAT.Sockets.Sock_Addr_Type;
      Timeout : Duration := 60.0)
   is
      use type GNAT.Sockets.Selector_Status;

      Selector : GNAT.Sockets.Selector_Type;
      Readable : GNAT.Sockets.Socket_Set_Type;
      Writable : GNAT.Sockets.Socket_Set_Type;
      Status   : GNAT.Sockets.Selector_Status;
   begin
      GNAT.Sockets.Create_Selector (Selector);
      GNAT.Sockets.Set (Readable, Server);
      GNAT.Sockets.Empty (Writable);

      GNAT.Sockets.Check_Selector
        (Selector, Readable, Writable, Status, Timeout);
      GNAT.Sockets.Close_Selector (Selector);

      if Status /= GNAT.Sockets.Completed then
         raise Program_Error with
           "mock server: no connection within"
           & Duration'Image (Timeout) & "s (status "
           & GNAT.Sockets.Selector_Status'Image (Status) & ")";
      end if;

      GNAT.Sockets.Accept_Socket (Server, Client, Peer);
   end Accept_With_Timeout;

   function Git_Program return String is
      use type GNAT.OS_Lib.String_Access;

      Found : GNAT.OS_Lib.String_Access :=
        GNAT.OS_Lib.Locate_Exec_On_Path ("git");
   begin
      if Found = null then
         return "/usr/bin/git";
      end if;

      return Result : constant String := Found.all do
         GNAT.OS_Lib.Free (Found);
      end return;
   end Git_Program;

end Version.Test_Support;
