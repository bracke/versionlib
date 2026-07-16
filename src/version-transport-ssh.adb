with Ada.Characters.Handling;
with Ada.Environment_Variables;
with Ada.IO_Exceptions;
with Ada.Strings;
with Ada.Strings.Fixed;
with CryptoLib.Errors;
with SSH_Lib.Config;

package body Version.Transport.Ssh is

   use type Ada.Streams.Stream_Element_Offset;

   function Starts_With
     (Value  : String;
      Prefix : String)
      return Boolean
   is
   begin
      return Value'Length >= Prefix'Length
        and then Value
          (Value'First .. Value'First + Prefix'Length - 1) = Prefix;
   end Starts_With;

   function Contains_Control (Value : String) return Boolean is
   begin
      for C of Value loop
         if C = Character'Val (0)
           or else Character'Pos (C) < 32
           or else Character'Pos (C) = 127
         then
            return True;
         end if;
      end loop;

      return False;
   end Contains_Control;

   function Is_Safe_User (Value : String) return Boolean is
      use Ada.Characters.Handling;
   begin
      if Value'Length = 0 or else Value (Value'First) = '-' then
         return False;
      end if;

      for C of Value loop
         if not (Is_Alphanumeric (C)
                 or else C = '_'
                 or else C = '-'
                 or else C = '.')
         then
            return False;
         end if;
      end loop;

      return True;
   end Is_Safe_User;

   function Is_Safe_Host (Value : String) return Boolean is
      use Ada.Characters.Handling;
   begin
      if Value'Length = 0 or else Value (Value'First) = '-' then
         return False;
      end if;

      for C of Value loop
         if not (Is_Alphanumeric (C)
                 or else C = '-'
                 or else C = '.')
         then
            return False;
         end if;
      end loop;

      return True;
   end Is_Safe_Host;

   function Is_Digits (Value : String) return Boolean is
   begin
      if Value'Length = 0 then
         return False;
      end if;

      for C of Value loop
         if C not in '0' .. '9' then
            return False;
         end if;
      end loop;

      return True;
   end Is_Digits;

   procedure Validate_Path (Value : String) is
   begin
      if Value'Length = 0
        or else Value = "/"
        or else Contains_Control (Value)
        or else Value (Value'First) = '-'
      then
         raise Ada.IO_Exceptions.Data_Error with
           "invalid SSH remote path";
      end if;
   end Validate_Path;

   procedure Validate_User_Host
     (User : String;
      Host : String)
   is
   begin
      if User'Length > 0 and then not Is_Safe_User (User) then
         raise Ada.IO_Exceptions.Data_Error with
           "invalid SSH remote user";
      end if;

      if not Is_Safe_Host (Host) then
         raise Ada.IO_Exceptions.Data_Error with
           "invalid SSH remote host";
      end if;
   end Validate_User_Host;

   function Single_Quote (Value : String) return String is
      Result : Unbounded_String := To_Unbounded_String ("'");
   begin
      for C of Value loop
         if C = Character'Val (39) then
            Append (Result, "'\''");
         else
            Append (Result, C);
         end if;
      end loop;

      Append (Result, "'");
      return To_String (Result);
   end Single_Quote;

   function Parse_Authority
     (Authority : String;
      Path      : String)
      return Ssh_Remote
   is
      At_Pos    : constant Natural := Ada.Strings.Fixed.Index (Authority, "@");
      User_Text : constant String :=
        (if At_Pos = 0 then "" else Authority (Authority'First .. At_Pos - 1));
      Host_Port : constant String :=
        (if At_Pos = 0 then Authority else Authority (At_Pos + 1 .. Authority'Last));
      Colon_Pos : constant Natural := Ada.Strings.Fixed.Index (Host_Port, ":");
      Host_Text : constant String :=
        (if Colon_Pos = 0 then Host_Port else Host_Port (Host_Port'First .. Colon_Pos - 1));
      Port_Text : constant String :=
        (if Colon_Pos = 0 then "" else Host_Port (Colon_Pos + 1 .. Host_Port'Last));
      Port_Value : Natural := 0;
   begin
      Validate_Path (Path);
      Validate_User_Host (User_Text, Host_Text);

      if Colon_Pos /= 0 and then Port_Text'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with
           "invalid SSH remote port";
      end if;

      if Port_Text'Length > 0 then
         if not Is_Digits (Port_Text) then
            raise Ada.IO_Exceptions.Data_Error with
              "invalid SSH remote port";
         end if;

         begin
            Port_Value := Natural'Value (Port_Text);
         exception
            when Constraint_Error =>
               raise Ada.IO_Exceptions.Data_Error with
                 "invalid SSH remote port";
         end;

         if Port_Value = 0 or else Port_Value > 65_535 then
            raise Ada.IO_Exceptions.Data_Error with
              "invalid SSH remote port";
         end if;
      end if;

      return
        (User => To_Unbounded_String (User_Text),
         Host => To_Unbounded_String (Host_Text),
         Path => To_Unbounded_String (Path),
         Port => Port_Value);
   end Parse_Authority;

   function Parse (Url : String) return Ssh_Remote is
      Prefix : constant String := "ssh://";
   begin
      if Url'Length = 0 or else Contains_Control (Url) then
         raise Ada.IO_Exceptions.Data_Error with
           "invalid SSH remote URL";
      end if;

      if Starts_With (Url, Prefix) then
         declare
            Rest      : constant String := Url (Url'First + Prefix'Length .. Url'Last);
            Slash_Pos : constant Natural := Ada.Strings.Fixed.Index (Rest, "/");
         begin
            if Slash_Pos = 0 or else Slash_Pos = Rest'First then
               raise Ada.IO_Exceptions.Data_Error with
                 "invalid SSH remote URL";
            end if;

            return Parse_Authority
              (Authority => Rest (Rest'First .. Slash_Pos - 1),
               Path      => Rest (Slash_Pos .. Rest'Last));
         end;
      else
         declare
            Colon_Pos : constant Natural := Ada.Strings.Fixed.Index (Url, ":");
         begin
            if Colon_Pos = 0 or else Colon_Pos = Url'First or else Colon_Pos = Url'Last then
               raise Ada.IO_Exceptions.Data_Error with
                 "invalid scp-like SSH remote URL";
            end if;

            return Parse_Authority
              (Authority => Url (Url'First .. Colon_Pos - 1),
               Path      => Url (Colon_Pos + 1 .. Url'Last));
         end;
      end if;
   end Parse;

   function User_Host_Argument (Remote : Ssh_Remote) return String is
      User : constant String := To_String (Remote.User);
      Host : constant String := To_String (Remote.Host);
   begin
      Validate_User_Host (User, Host);

      if User'Length = 0 then
         return Host;
      else
         return User & "@" & Host;
      end if;
   end User_Host_Argument;

   function Upload_Pack_Remote_Command (Remote : Ssh_Remote) return String is
      Path : constant String := To_String (Remote.Path);
   begin
      Validate_Path (Path);
      return "git-upload-pack " & Single_Quote (Path);
   end Upload_Pack_Remote_Command;

   function Receive_Pack_Remote_Command (Remote : Ssh_Remote) return String is
      Path : constant String := To_String (Remote.Path);
   begin
      Validate_Path (Path);
      return "git-receive-pack " & Single_Quote (Path);
   end Receive_Pack_Remote_Command;

   function LFS_Authenticate_Remote_Command
     (Remote    : Ssh_Remote;
      Operation : String) return String
   is
      Path : constant String := To_String (Remote.Path);
   begin
      Validate_Path (Path);

      if Operation /= "download" and then Operation /= "upload" then
         raise Ada.IO_Exceptions.Data_Error with
           "invalid Git LFS authenticate operation";
      end if;

      return "git-lfs-authenticate " & Single_Quote (Path) & " " & Operation;
   end LFS_Authenticate_Remote_Command;

   function LFS_Transfer_Remote_Command
     (Remote    : Ssh_Remote;
      Operation : String) return String
   is
      Path : constant String := To_String (Remote.Path);
   begin
      Validate_Path (Path);

      if Operation /= "download" and then Operation /= "upload" then
         raise Ada.IO_Exceptions.Data_Error with
           "invalid Git LFS transfer operation";
      end if;

      return "git-lfs-transfer " & Single_Quote (Path) & " " & Operation;
   end LFS_Transfer_Remote_Command;

   function Build_Service_Command
     (Remote  : Ssh_Remote;
      Service : String)
      return Ssh_Service_Command
   is
      Result : Ssh_Service_Command;
   begin
      Result.Program := To_Unbounded_String ("ssh");
      Result.Host_Argument :=
        To_Unbounded_String (User_Host_Argument (Remote));

      if Remote.Port /= 0 then
         Result.Has_Port := True;
         Result.Port_Option := To_Unbounded_String ("-p");
         Result.Port_Value :=
           To_Unbounded_String (Ada.Strings.Fixed.Trim
             (Natural'Image (Remote.Port), Ada.Strings.Both));
      end if;

      if Service = "upload-pack" then
         Result.Remote_Command :=
           To_Unbounded_String (Upload_Pack_Remote_Command (Remote));
      elsif Service = "receive-pack" then
         Result.Remote_Command :=
           To_Unbounded_String (Receive_Pack_Remote_Command (Remote));
      elsif Service = "lfs-authenticate-download" then
         Result.Remote_Command :=
           To_Unbounded_String
             (LFS_Authenticate_Remote_Command (Remote, "download"));
      elsif Service = "lfs-authenticate-upload" then
         Result.Remote_Command :=
           To_Unbounded_String
             (LFS_Authenticate_Remote_Command (Remote, "upload"));
      else
         raise Ada.IO_Exceptions.Data_Error with
           "invalid SSH Git service";
      end if;

      return Result;
   end Build_Service_Command;

   function Upload_Pack_Service_Command
     (Remote : Ssh_Remote)
      return Ssh_Service_Command
   is
   begin
      return Build_Service_Command (Remote, "upload-pack");
   end Upload_Pack_Service_Command;

   function Receive_Pack_Service_Command
     (Remote : Ssh_Remote)
      return Ssh_Service_Command
   is
   begin
      return Build_Service_Command (Remote, "receive-pack");
   end Receive_Pack_Service_Command;

   function LFS_Authenticate_Service_Command
     (Remote    : Ssh_Remote;
      Operation : String) return Ssh_Service_Command
   is
   begin
      if Operation = "download" then
         return Build_Service_Command (Remote, "lfs-authenticate-download");
      elsif Operation = "upload" then
         return Build_Service_Command (Remote, "lfs-authenticate-upload");
      else
         raise Ada.IO_Exceptions.Data_Error with
           "invalid Git LFS authenticate operation";
      end if;
   end LFS_Authenticate_Service_Command;

   function Argument_Count (Command : Ssh_Service_Command) return Natural is
   begin
      if Command.Has_Port then
         return 4;
      else
         return 2;
      end if;
   end Argument_Count;

   function Argument
     (Command : Ssh_Service_Command;
      Index   : Positive) return String
   is
   begin
      if Command.Has_Port then
         case Index is
            when 1 =>
               return To_String (Command.Port_Option);
            when 2 =>
               return To_String (Command.Port_Value);
            when 3 =>
               return To_String (Command.Host_Argument);
            when 4 =>
               return To_String (Command.Remote_Command);
            when others =>
               raise Ada.IO_Exceptions.Data_Error with
                 "SSH command argument index out of range";
         end case;
      else
         case Index is
            when 1 =>
               return To_String (Command.Host_Argument);
            when 2 =>
               return To_String (Command.Remote_Command);
            when others =>
               raise Ada.IO_Exceptions.Data_Error with
                 "SSH command argument index out of range";
         end case;
      end if;
   end Argument;

   --  A user-facing message for a failed SSH connection/authentication that
   --  names the remote and hints at the likely cause (the raw status alone,
   --  e.g. AUTHENTICATION_FAILED, is opaque).
   function Ssh_Connect_Error
     (Remote : String; Status : CryptoLib.Errors.Status) return String
   is
      Hint : constant String :=
        (case Status is
            when CryptoLib.Errors.Authentication_Failed =>
              " (no usable credentials -- check the key in ~/.ssh/config"
              & " IdentityFile or an ssh-agent, and that it is authorized)",
            when CryptoLib.Errors.Host_Key_Unknown =>
              " (host key not in known_hosts)",
            when CryptoLib.Errors.Host_Key_Mismatch =>
              " (host key changed -- possible man-in-the-middle,"
              & " or the server was rekeyed)",
            when CryptoLib.Errors.Connection_Failed =>
              " (could not connect -- check the host and port)",
            when CryptoLib.Errors.Timeout =>
              " (connection timed out)",
            when CryptoLib.Errors.Invalid_Host =>
              " (invalid host)",
            when others => "");
   begin
      return "cannot open SSH connection to " & Remote & ": "
        & CryptoLib.Errors.Status'Image (Status) & Hint;
   end Ssh_Connect_Error;

   --  Open a native SSH session for Remote_Text (via ssh_lib, no system `ssh`)
   --  and start Remote_Command (e.g. "git-upload-pack '<path>'") on an exec
   --  channel. Connection settings (host, port, user, identity files,
   --  known_hosts) are resolved through the user's ~/.ssh/config by ssh_lib,
   --  with the URL's explicit user/port taking precedence. The channel is then
   --  used as a raw bidirectional pipe by the existing pkt-line/pack code.
   procedure Open_Channel
     (Remote_Text    : String;
      Remote_Command : String;
      Stream         : in out Ssh_Stream)
   is
      Default_User : constant String :=
        (if Ada.Environment_Variables.Exists ("USER")
         then Ada.Environment_Variables.Value ("USER") else "");
      Options : SSH_Lib.Sessions.Session_Options;
      Status  : CryptoLib.Errors.Status;
   begin
      if Stream.Opened then
         Close (Stream);
      end if;

      Status := SSH_Lib.Config.Resolve_Remote
        (SSH_Lib.Config.Load_Default, Remote_Text, Default_User, Options);
      if not CryptoLib.Errors.Is_Success (Status) then
         raise Ada.IO_Exceptions.Use_Error with
           "failed to resolve SSH remote: "
           & CryptoLib.Errors.Status'Image (Status);
      end if;

      Status := SSH_Lib.Sessions.Open (Options, Stream.Session);
      if not CryptoLib.Errors.Is_Success (Status) then
         raise Ada.IO_Exceptions.Use_Error
           with Ssh_Connect_Error (Remote_Text, Status);
      end if;

      Status := SSH_Lib.Channels.Open_Exec
        (Stream.Session, Remote_Command, Stream.Channel);
      if not CryptoLib.Errors.Is_Success (Status) then
         declare
            Ignore : constant CryptoLib.Errors.Status :=
              SSH_Lib.Sessions.Close (Stream.Session);
         begin
            null;
         end;
         raise Ada.IO_Exceptions.Use_Error with
           "failed to start SSH transport command: "
           & CryptoLib.Errors.Status'Image (Status);
      end if;

      Stream.Opened := True;
   end Open_Channel;

   procedure Open_Upload_Pack
     (Url    : String;
      Stream : in out Ssh_Stream)
   is
      Remote : constant Ssh_Remote := Parse (Url);
   begin
      Open_Channel (Url, Upload_Pack_Remote_Command (Remote), Stream);
   end Open_Upload_Pack;

   procedure Open_Receive_Pack
     (Url    : String;
      Stream : in out Ssh_Stream)
   is
      Remote : constant Ssh_Remote := Parse (Url);
   begin
      Open_Channel (Url, Receive_Pack_Remote_Command (Remote), Stream);
   end Open_Receive_Pack;

   procedure Open_LFS_Authenticate
     (Url       : String;
      Operation : String;
      Stream    : in out Ssh_Stream)
   is
      Remote : constant Ssh_Remote := Parse (Url);
   begin
      Open_Channel
        (Url, LFS_Authenticate_Remote_Command (Remote, Operation), Stream);
   end Open_LFS_Authenticate;

   procedure Open_LFS_Transfer
     (Url       : String;
      Operation : String;
      Stream    : in out Ssh_Stream)
   is
      Remote : constant Ssh_Remote := Parse (Url);
   begin
      Open_Channel
        (Url, LFS_Transfer_Remote_Command (Remote, Operation), Stream);
   end Open_LFS_Transfer;

   procedure Write
     (Stream : in out Ssh_Stream;
      Data   : Ada.Streams.Stream_Element_Array)
   is
      Status : CryptoLib.Errors.Status;
   begin
      if not Stream.Opened then
         raise Ada.IO_Exceptions.Use_Error with "SSH stream is not open";
      end if;
      if Data'Length = 0 then
         return;
      end if;

      Status := SSH_Lib.Channels.Write (Stream.Channel, Data);
      if not CryptoLib.Errors.Is_Success (Status) then
         raise Ada.IO_Exceptions.Use_Error with
           "failed to write to SSH channel: "
           & CryptoLib.Errors.Status'Image (Status);
      end if;
   end Write;

   procedure Read_Some
     (Stream : in out Ssh_Stream;
      Buffer : out Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset)
   is
      use type CryptoLib.Errors.Status;
      Status : CryptoLib.Errors.Status;
   begin
      if not Stream.Opened then
         raise Ada.IO_Exceptions.Use_Error with "SSH stream is not open";
      end if;

      Status := SSH_Lib.Channels.Read_Some (Stream.Channel, Buffer, Last);
      if Status = CryptoLib.Errors.End_Of_Stream then
         Last := Buffer'First - 1;  --  clean EOF
      elsif not CryptoLib.Errors.Is_Success (Status) then
         raise Ada.IO_Exceptions.Use_Error with
           "failed to read from SSH channel: "
           & CryptoLib.Errors.Status'Image (Status);
      end if;
   end Read_Some;

   procedure Close
     (Stream : in out Ssh_Stream)
   is
      Ignore : CryptoLib.Errors.Status;
   begin
      if not Stream.Opened then
         return;
      end if;

      Stream.Opened := False;
      Ignore := SSH_Lib.Channels.Send_EOF (Stream.Channel);
      Ignore := SSH_Lib.Channels.Close (Stream.Channel);
      Ignore := SSH_Lib.Sessions.Close (Stream.Session);
   end Close;

end Version.Transport.Ssh;
