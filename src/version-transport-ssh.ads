with Ada.Streams;
with Ada.Strings.Unbounded;
with SSH_Lib.Sessions;
with SSH_Lib.Channels;

package Version.Transport.Ssh is

   use Ada.Strings.Unbounded;

   type Ssh_Remote is record
      User : Unbounded_String;
      Host : Unbounded_String;
      Path : Unbounded_String;
      Port : Natural := 0;
   end record;

   type Ssh_Stream is limited private;

   type Ssh_Service_Command is record
      Program        : Unbounded_String;
      Has_Port       : Boolean := False;
      Port_Option    : Unbounded_String;
      Port_Value     : Unbounded_String;
      Host_Argument  : Unbounded_String;
      Remote_Command : Unbounded_String;
   end record;

   function Parse (Url : String) return Ssh_Remote;

   function User_Host_Argument (Remote : Ssh_Remote) return String;

   function Upload_Pack_Remote_Command (Remote : Ssh_Remote) return String;

   function Receive_Pack_Remote_Command (Remote : Ssh_Remote) return String;

   function LFS_Authenticate_Remote_Command
     (Remote    : Ssh_Remote;
      Operation : String) return String;

   function LFS_Transfer_Remote_Command
     (Remote    : Ssh_Remote;
      Operation : String) return String;
   --  "git-lfs-transfer '<path>' <download|upload>" -- the pure-SSH LFS
   --  transfer protocol (bytes travel over the SSH channel, no HTTP handoff).

   function Upload_Pack_Service_Command
     (Remote : Ssh_Remote) return Ssh_Service_Command;

   function Receive_Pack_Service_Command
     (Remote : Ssh_Remote) return Ssh_Service_Command;

   function LFS_Authenticate_Service_Command
     (Remote    : Ssh_Remote;
      Operation : String) return Ssh_Service_Command;

   function Argument_Count (Command : Ssh_Service_Command) return Natural;
   --  Number of local process arguments after the program name.  This is
   --  always 2 without a port (host, remote command) and 4 with a port
   --  (-p, port, host, remote command).

   function Argument
     (Command : Ssh_Service_Command;
      Index   : Positive) return String;
   --  Return one local process argument in deterministic spawn order.
   --  This describes a direct spawn of ssh and never a local shell command.

   procedure Open_Upload_Pack
     (Url    : String;
      Stream : in out Ssh_Stream);

   procedure Open_Receive_Pack
     (Url    : String;
      Stream : in out Ssh_Stream);

   procedure Open_LFS_Authenticate
     (Url       : String;
      Operation : String;
      Stream    : in out Ssh_Stream);

   procedure Open_LFS_Transfer
     (Url       : String;
      Operation : String;
      Stream    : in out Ssh_Stream);
   --  Open a channel running `git-lfs-transfer` for the pure-SSH LFS protocol.

   procedure Write
     (Stream : in out Ssh_Stream;
      Data   : Ada.Streams.Stream_Element_Array);

   procedure Read_Some
     (Stream : in out Ssh_Stream;
      Buffer : out Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset);

   procedure Close
     (Stream : in out Ssh_Stream);

private

   type Ssh_Stream is limited record
      Opened  : Boolean := False;
      Session : SSH_Lib.Sessions.Session;
      Channel : SSH_Lib.Channels.Channel;
   end record;

end Version.Transport.Ssh;
