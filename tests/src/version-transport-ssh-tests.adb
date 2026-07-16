with Ada.Exceptions;
with Ada.IO_Exceptions;

with AUnit.Assertions;
with AUnit.Test_Cases;

package body Version.Transport.Ssh.Tests is

   use AUnit.Assertions;

   procedure Parses_Ssh_Url (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Remote : constant Version.Transport.Ssh.Ssh_Remote :=
        Version.Transport.Ssh.Parse ("ssh://git@example.com/path/to/repo.git");
   begin
      Assert (To_String (Remote.User) = "git", "SSH URL user parsed");
      Assert (To_String (Remote.Host) = "example.com", "SSH URL host parsed");
      Assert (To_String (Remote.Path) = "/path/to/repo.git", "SSH URL path parsed");
      Assert (Remote.Port = 0, "SSH URL default port is zero");
   end Parses_Ssh_Url;

   procedure Parses_Ssh_Url_With_Port (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Remote : constant Version.Transport.Ssh.Ssh_Remote :=
        Version.Transport.Ssh.Parse ("ssh://git@example.com:2222/repo.git");
   begin
      Assert (To_String (Remote.User) = "git", "SSH URL user parsed");
      Assert (To_String (Remote.Host) = "example.com", "SSH URL host parsed");
      Assert (To_String (Remote.Path) = "/repo.git", "SSH URL path parsed");
      Assert (Remote.Port = 2222, "SSH URL optional port parsed");
   end Parses_Ssh_Url_With_Port;

   procedure Parses_Scp_Like_Url (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Remote : constant Version.Transport.Ssh.Ssh_Remote :=
        Version.Transport.Ssh.Parse ("git@example.com:team/repo.git");
   begin
      Assert (To_String (Remote.User) = "git", "scp-like user parsed");
      Assert (To_String (Remote.Host) = "example.com", "scp-like host parsed");
      Assert (To_String (Remote.Path) = "team/repo.git", "scp-like path parsed");
   end Parses_Scp_Like_Url;

   procedure Classifies_Ssh_Remotes (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Assert
        (Version.Transport.Detect_Transport ("ssh://example.com/repo.git")
         = Version.Transport.Ssh_Transport,
         "ssh:// remotes classify as SSH");

      Assert
        (Version.Transport.Detect_Transport ("git@example.com:repo.git")
         = Version.Transport.Ssh_Transport,
         "user@host:path remotes classify as SSH");

      Assert
        (Version.Transport.Detect_Transport ("example.com:repo.git")
         = Version.Transport.Ssh_Transport,
         "host:path remotes classify as SSH");
   end Classifies_Ssh_Remotes;

   procedure Does_Not_Classify_Windows_Drive_As_Ssh (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Assert
        (Version.Transport.Detect_Transport ("C:\\repo\\work")
         = Version.Transport.Local_Transport,
         "Windows drive path must remain local");

      Assert
        (Version.Transport.Detect_Transport ("D:/repo/work")
         = Version.Transport.Local_Transport,
         "Windows slash drive path must remain local");

      Assert
        (Version.Transport.Detect_Transport ("E:repo\work")
         = Version.Transport.Local_Transport,
         "Windows drive-relative path must remain local");
   end Does_Not_Classify_Windows_Drive_As_Ssh;

   procedure Builds_Upload_And_Receive_Commands (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Remote : constant Version.Transport.Ssh.Ssh_Remote :=
        Version.Transport.Ssh.Parse ("git@example.com:team/repo.git");

      Upload_Command : constant Version.Transport.Ssh.Ssh_Service_Command :=
        Version.Transport.Ssh.Upload_Pack_Service_Command (Remote);

      Receive_Command : constant Version.Transport.Ssh.Ssh_Service_Command :=
        Version.Transport.Ssh.Receive_Pack_Service_Command (Remote);
   begin
      Assert
        (Version.Transport.Ssh.User_Host_Argument (Remote) = "git@example.com",
         "SSH host argument uses user@host");

      Assert
        (Version.Transport.Ssh.Upload_Pack_Remote_Command (Remote)
         = "git-upload-pack 'team/repo.git'",
         "upload-pack command is constructed deterministically");

      Assert
        (Version.Transport.Ssh.Receive_Pack_Remote_Command (Remote)
         = "git-receive-pack 'team/repo.git'",
         "receive-pack command is constructed deterministically");

      Assert
        (To_String (Upload_Command.Program) = "ssh",
         "upload-pack command program is ssh");

      Assert
        (not Upload_Command.Has_Port,
         "upload-pack command omits port arguments when no port was supplied");

      Assert
        (To_String (Upload_Command.Host_Argument) = "git@example.com",
         "upload-pack command host argument is deterministic");

      Assert
        (To_String (Upload_Command.Remote_Command)
         = "git-upload-pack 'team/repo.git'",
         "upload-pack command remote service argument is deterministic");

      Assert
        (To_String (Receive_Command.Remote_Command)
         = "git-receive-pack 'team/repo.git'",
         "receive-pack command remote service argument is deterministic");

      Assert
        (Version.Transport.Ssh.Argument_Count (Upload_Command) = 2,
         "upload-pack command has host and remote command arguments");

      Assert
        (Version.Transport.Ssh.Argument (Upload_Command, 1) = "git@example.com",
         "first upload-pack process argument is host/userhost");

      Assert
        (Version.Transport.Ssh.Argument (Upload_Command, 2)
         = "git-upload-pack 'team/repo.git'",
         "second upload-pack process argument is remote command string");
   end Builds_Upload_And_Receive_Commands;

   procedure Builds_Port_Aware_Command (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Remote : constant Version.Transport.Ssh.Ssh_Remote :=
        Version.Transport.Ssh.Parse ("ssh://git@example.com:2222/team/repo.git");

      Command : constant Version.Transport.Ssh.Ssh_Service_Command :=
        Version.Transport.Ssh.Upload_Pack_Service_Command (Remote);
   begin
      Assert (Command.Has_Port, "port-aware command marks port as present");
      Assert (To_String (Command.Port_Option) = "-p", "ssh port option is -p");
      Assert (To_String (Command.Port_Value) = "2222", "ssh port value is preserved");
      Assert
        (To_String (Command.Host_Argument) = "git@example.com",
         "port is not included in the ssh host argument");
      Assert
        (To_String (Command.Remote_Command) = "git-upload-pack '/team/repo.git'",
         "ssh:// remote command preserves absolute path slash");

      Assert
        (Version.Transport.Ssh.Argument_Count (Command) = 4,
         "port-aware ssh command has four local process arguments");

      Assert
        (Version.Transport.Ssh.Argument (Command, 1) = "-p",
         "first port-aware process argument is ssh port option");

      Assert
        (Version.Transport.Ssh.Argument (Command, 2) = "2222",
         "second port-aware process argument is ssh port value");

      Assert
        (Version.Transport.Ssh.Argument (Command, 3) = "git@example.com",
         "third port-aware process argument is host/userhost");

      Assert
        (Version.Transport.Ssh.Argument (Command, 4)
         = "git-upload-pack '/team/repo.git'",
         "fourth port-aware process argument is remote command string");
   end Builds_Port_Aware_Command;

   procedure Rejects_Invalid_Argument_Index
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Plain_Remote : constant Version.Transport.Ssh.Ssh_Remote :=
        Version.Transport.Ssh.Parse ("git@example.com:team/repo.git");
      Plain_Command : constant Version.Transport.Ssh.Ssh_Service_Command :=
        Version.Transport.Ssh.Upload_Pack_Service_Command (Plain_Remote);
      Port_Remote : constant Version.Transport.Ssh.Ssh_Remote :=
        Version.Transport.Ssh.Parse
          ("ssh://git@example.com:2222/team/repo.git");
      Port_Command : constant Version.Transport.Ssh.Ssh_Service_Command :=
        Version.Transport.Ssh.Upload_Pack_Service_Command (Port_Remote);

      procedure Assert_Invalid
        (Command : Version.Transport.Ssh.Ssh_Service_Command;
         Index   : Positive;
         Context : String)
      is
         Raised : Boolean := False;
      begin
         begin
            declare
               Ignored : constant String :=
                 Version.Transport.Ssh.Argument (Command, Index);
            begin
               pragma Unreferenced (Ignored);
            end;
         exception
            when E : Ada.IO_Exceptions.Data_Error =>
               Raised := True;
               Assert
                 (Ada.Exceptions.Exception_Message (E)
                  = "SSH command argument index out of range",
                  Context & " diagnostic must remain stable");
         end;

         Assert (Raised, Context & " must raise Data_Error");
      end Assert_Invalid;
   begin
      Assert_Invalid
        (Plain_Command,
         Version.Transport.Ssh.Argument_Count (Plain_Command) + 1,
         "plain SSH command out-of-range argument");
      Assert_Invalid
        (Port_Command,
         Version.Transport.Ssh.Argument_Count (Port_Command) + 1,
         "port SSH command out-of-range argument");
   end Rejects_Invalid_Argument_Index;

   procedure Builds_LFS_Authenticate_Command
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Remote : constant Version.Transport.Ssh.Ssh_Remote :=
        Version.Transport.Ssh.Parse ("git@example.com:team/repo.git");
      Command : constant Version.Transport.Ssh.Ssh_Service_Command :=
        Version.Transport.Ssh.LFS_Authenticate_Service_Command
          (Remote, "download");
   begin
      Assert
        (Version.Transport.Ssh.LFS_Authenticate_Remote_Command
           (Remote, "download")
         = "git-lfs-authenticate 'team/repo.git' download",
         "LFS authenticate remote command must quote the repo path and operation");
      Assert
        (Version.Transport.Ssh.Argument_Count (Command) = 2,
         "LFS authenticate command uses host and remote command argv");
      Assert
        (Version.Transport.Ssh.Argument (Command, 1) = "git@example.com",
         "LFS authenticate command keeps host argv separate");
      Assert
        (Version.Transport.Ssh.Argument (Command, 2)
         = "git-lfs-authenticate 'team/repo.git' download",
         "LFS authenticate command keeps remote command as one argv item");
   end Builds_LFS_Authenticate_Command;

   procedure Builds_LFS_Transfer_Command
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Remote : constant Version.Transport.Ssh.Ssh_Remote :=
        Version.Transport.Ssh.Parse ("git@example.com:team/repo.git");
   begin
      Assert
        (Version.Transport.Ssh.LFS_Transfer_Remote_Command (Remote, "upload")
         = "git-lfs-transfer 'team/repo.git' upload",
         "LFS transfer remote command must quote the repo path and operation");
      Assert
        (Version.Transport.Ssh.LFS_Transfer_Remote_Command (Remote, "download")
         = "git-lfs-transfer 'team/repo.git' download",
         "LFS transfer download command must be built");
   end Builds_LFS_Transfer_Command;

   procedure Rejects_Invalid_Port (T : in out AUnit.Test_Cases.Test_Case'Class) is
      Remote : Version.Transport.Ssh.Ssh_Remote;
      pragma Unreferenced (T);
      pragma Unreferenced (Remote);
   begin
      begin
         Remote := Version.Transport.Ssh.Parse
           ("ssh://git@example.com:0/repo.git");
         Assert (False, "zero SSH port should raise Data_Error");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            null;
      end;

      begin
         Remote := Version.Transport.Ssh.Parse
           ("ssh://git@example.com:70000/repo.git");
         Assert (False, "out-of-range SSH port should raise Data_Error");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            null;
      end;

      begin
         Remote := Version.Transport.Ssh.Parse
           ("ssh://git@example.com:/repo.git");
         Assert (False, "empty SSH port should raise Data_Error");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            null;
      end;

      begin
         Remote := Version.Transport.Ssh.Parse
           ("ssh://git@example.com:abc/repo.git");
         Assert (False, "nonnumeric SSH port should raise Data_Error");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            null;
      end;
   end Rejects_Invalid_Port;

   procedure Escapes_Single_Quote_In_Path (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Remote : constant Version.Transport.Ssh.Ssh_Remote :=
      Version.Transport.Ssh.Parse ("git@example.com:team/repo'one.git");
   begin
      Assert
        (Version.Transport.Ssh.Upload_Pack_Remote_Command (Remote)
         = "git-upload-pack 'team/repo'\''one.git'",
         "single quotes in remote paths are shell-escaped for ssh remote command");
   end Escapes_Single_Quote_In_Path;

   procedure Rejects_Missing_Ssh_Path (T : in out AUnit.Test_Cases.Test_Case'Class) is
      Remote : Version.Transport.Ssh.Ssh_Remote;
      pragma Unreferenced (T);
      pragma Unreferenced (Remote);
   begin
      begin
         Remote := Version.Transport.Ssh.Parse ("ssh://example.com/");
         Assert (False, "bare ssh://host/ path should raise Data_Error");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            null;
      end;

      begin
         Remote := Version.Transport.Ssh.Parse ("ssh://example.com");
         Assert (False, "ssh://host without a slash path should raise Data_Error");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            null;
      end;
   end Rejects_Missing_Ssh_Path;

   procedure Parses_Double_Slash_Absolute_Path (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Remote : constant Version.Transport.Ssh.Ssh_Remote :=
        Version.Transport.Ssh.Parse ("ssh://example.com//srv/git/repo.git");
   begin
      Assert
        (To_String (Remote.Path) = "//srv/git/repo.git",
         "ssh://host//absolute path preserves doubled slash for remote shell");
   end Parses_Double_Slash_Absolute_Path;

   procedure Rejects_Option_Like_Components (T : in out AUnit.Test_Cases.Test_Case'Class) is
      Remote : Version.Transport.Ssh.Ssh_Remote;
      pragma Unreferenced (T);
      pragma Unreferenced (Remote);
   begin
      begin
         Remote := Version.Transport.Ssh.Parse ("-example.com:repo.git");
         Assert (False, "option-like SSH host should raise Data_Error");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            null;
      end;

      begin
         Remote := Version.Transport.Ssh.Parse ("-git@example.com:repo.git");
         Assert (False, "option-like SSH user should raise Data_Error");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            null;
      end;

      begin
         Remote := Version.Transport.Ssh.Parse ("example.com:-repo.git");
         Assert (False, "option-like relative repository path should raise Data_Error");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            null;
      end;
   end Rejects_Option_Like_Components;

   procedure Rejects_Control_Characters (T : in out AUnit.Test_Cases.Test_Case'Class) is
      Remote : Version.Transport.Ssh.Ssh_Remote;
      pragma Unreferenced (T);
      pragma Unreferenced (Remote);
   begin
      begin
         Remote := Version.Transport.Ssh.Parse
           ("ssh://git@example.com/repo" & Character'Val (10) & ".git");
         Assert (False, "control character in SSH URL should raise Data_Error");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            null;
      end;
   end Rejects_Control_Characters;

   overriding procedure Register_Tests
     (T : in out Test_Case)
   is
   begin
      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Parses_Ssh_Url'Access,
         "Transport.Ssh: parses ssh URL");

      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Parses_Ssh_Url_With_Port'Access,
         "Transport.Ssh: parses ssh URL with port");

      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Parses_Scp_Like_Url'Access,
         "Transport.Ssh: parses scp-like URL");

      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Classifies_Ssh_Remotes'Access,
         "Transport: classifies SSH remotes");

      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Does_Not_Classify_Windows_Drive_As_Ssh'Access,
         "Transport: does not classify Windows drive paths as SSH");

      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Builds_Upload_And_Receive_Commands'Access,
         "Transport.Ssh: builds upload-pack and receive-pack commands");

      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Builds_LFS_Authenticate_Command'Access,
         "Transport.Ssh: builds git-lfs-authenticate command");

      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Builds_LFS_Transfer_Command'Access,
         "Transport.Ssh: builds git-lfs-transfer command");

      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Builds_Port_Aware_Command'Access,
         "Transport.Ssh: builds port-aware command arguments");

      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Rejects_Invalid_Argument_Index'Access,
         "Transport.Ssh: rejects invalid command argument indexes");

      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Escapes_Single_Quote_In_Path'Access,
         "Transport.Ssh: escapes single quotes in remote paths");

      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Rejects_Invalid_Port'Access,
         "Transport.Ssh: rejects invalid ports");

      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Rejects_Missing_Ssh_Path'Access,
         "Transport.Ssh: rejects missing ssh URL paths");

      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Parses_Double_Slash_Absolute_Path'Access,
         "Transport.Ssh: preserves double-slash absolute paths");

      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Rejects_Option_Like_Components'Access,
         "Transport.Ssh: rejects option-like URL components");

      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Rejects_Control_Characters'Access,
         "Transport.Ssh: rejects control characters");

   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Transport.Ssh");
   end Name;

end Version.Transport.Ssh.Tests;
