with Ada.Containers.Vectors;
with Ada.Streams;
with Ada.Strings.Unbounded;

with Version.Objects;
with Version.Repository;

package Version.Receive_Pack is

   use Ada.Strings.Unbounded;

   type Advertised_Ref is record
      Name : Unbounded_String;
      Id   : Version.Objects.Object_Id_Storage;
   end record;

   package Advertised_Ref_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Advertised_Ref);

   type Discovery_Result is record
      Refs         : Advertised_Ref_Vectors.Vector;
      Capabilities : Unbounded_String;
   end record;

   function Parse_Discovery
     (Data : Ada.Streams.Stream_Element_Array)
      return Discovery_Result;
   --  Parse a smart HTTP git-receive-pack discovery advertisement.  The
   --  parser accepts protocol v0/v1 service advertisements and extracts the
   --  first-ref NUL capability list.  Phase 7 requires report-status.

   function Parse_Advertisement
     (Data : Ada.Streams.Stream_Element_Array)
      return Discovery_Result;
   --  Parse a raw SSH git-receive-pack advertisement.  Unlike smart HTTP
   --  discovery, this form starts directly with advertised refs and has no
   --  service header packet.

   function Build_Update_Command
     (Old_Id       : String;
      New_Id       : String;
      Ref_Name     : String;
      Capabilities : String)
      return Ada.Streams.Stream_Element_Array;
   --  Build the first receive-pack command pkt-line payload for one branch
   --  create/update. Old_Id may be the all-zero id for branch creation.

   function Build_Request
     (Old_Id       : String;
      New_Id       : String;
      Ref_Name     : String;
      Capabilities : String;
      Pack         : Ada.Streams.Stream_Element_Array)
      return Ada.Streams.Stream_Element_Array;
   --  Build command pkt-line, flush packet, and raw pack bytes.

   function Build_Request_From_Pack_File
     (Old_Id       : String;
      New_Id       : String;
      Ref_Name     : String;
      Capabilities : String;
      Pack_Path    : String)
      return Ada.Streams.Stream_Element_Array;
   --  Build command pkt-line, flush packet, and raw pack bytes by reading the
   --  pack file directly into the final request buffer.  This avoids the
   --  older push path's separate whole-pack buffer followed by a second
   --  whole-request buffer.

   procedure Parse_Report_Status
     (Response_Bytes : Ada.Streams.Stream_Element_Array;
      Ref_Name       : String);
   --  Parse non-sideband report-status pkt-lines.  Success requires
   --  "unpack ok" and "ok <Ref_Name>".  Any unpack failure, ng ref status,
   --  malformed pkt-line, or missing success line raises Data_Error.

   procedure Push_Branch
     (Repo        : Version.Repository.Repository_Handle;
      Remote_Name : String;
      Url         : String;
      Branch_Name : String;
      Force       : Boolean := False);
   --  Push refs/heads/Branch_Name to Url using smart HTTP receive-pack.
   --  Force skips the fast-forward (ancestor) check.

   procedure Push_Branch_Ssh
     (Repo        : Version.Repository.Repository_Handle;
      Remote_Name : String;
      Url         : String;
      Branch_Name : String;
      Force       : Boolean := False);
   --  Push refs/heads/Branch_Name to Url using SSH receive-pack.
   --  Force skips the fast-forward (ancestor) check.

   procedure Push_Tag
     (Repo        : Version.Repository.Repository_Handle;
      Remote_Name : String;
      Url         : String;
      Tag_Name    : String;
      Object_Id   : Version.Objects.Hex_Object_Id;
      Force       : Boolean := False);
   --  Push refs/tags/Tag_Name (-> Object_Id) to Url using smart HTTP
   --  receive-pack. Refuses to overwrite an existing, different remote tag
   --  unless Force.

   procedure Push_Tag_Ssh
     (Repo        : Version.Repository.Repository_Handle;
      Remote_Name : String;
      Url         : String;
      Tag_Name    : String;
      Object_Id   : Version.Objects.Hex_Object_Id;
      Force       : Boolean := False);
   --  Push refs/tags/Tag_Name (-> Object_Id) to Url using SSH receive-pack.

   procedure Delete_Ref
     (Repo        : Version.Repository.Repository_Handle;
      Remote_Name : String;
      Url         : String;
      Ref_Name    : String);
   --  Delete Ref_Name on Url using smart HTTP receive-pack (a delete-only
   --  command, no pack). Errors if the ref is absent on the remote.

   procedure Delete_Ref_Ssh
     (Repo        : Version.Repository.Repository_Handle;
      Remote_Name : String;
      Url         : String;
      Ref_Name    : String);
   --  Delete Ref_Name on Url using SSH receive-pack (a delete-only command).

   procedure Push_Ref
     (Repo        : Version.Repository.Repository_Handle;
      Remote_Name : String;
      Url         : String;
      Ref_Name    : String;
      New_Id      : Version.Objects.Hex_Object_Id;
      Force       : Boolean := False);
   --  Push New_Id to Ref_Name (refs/heads/* or refs/tags/*) on Url using
   --  smart HTTP receive-pack. Refuses a non-fast-forward update unless Force.

   procedure Push_Ref_Ssh
     (Repo        : Version.Repository.Repository_Handle;
      Remote_Name : String;
      Url         : String;
      Ref_Name    : String;
      New_Id      : Version.Objects.Hex_Object_Id;
      Force       : Boolean := False);
   --  Push New_Id to Ref_Name on Url using SSH receive-pack.

   --  One ref update in an atomic batch. New_Id is the target commit/tag id, or
   --  the all-zero id to delete Ref_Name.
   type Push_Command is record
      Ref_Name : Unbounded_String;
      New_Id   : Unbounded_String;
   end record;

   package Push_Command_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Push_Command);

   procedure Push_Atomic
     (Repo        : Version.Repository.Repository_Handle;
      Remote_Name : String;
      Url         : String;
      Commands    : Push_Command_Vectors.Vector;
      Force       : Boolean := False);
   --  Apply all Commands in a single smart-HTTP receive-pack request using the
   --  `atomic` capability (all-or-nothing). Raises if the remote does not
   --  advertise `atomic`, if any update is a rejected non-fast-forward (unless
   --  Force), or if the server reports any `ng`.

   procedure Push_Atomic_Ssh
     (Repo        : Version.Repository.Repository_Handle;
      Remote_Name : String;
      Url         : String;
      Commands    : Push_Command_Vectors.Vector;
      Force       : Boolean := False);
   --  As Push_Atomic, over SSH receive-pack.

   function Discover_Http (Url : String) return Discovery_Result;
   --  The receive-pack ref advertisement (refs + capabilities) from a smart
   --  HTTP remote, for listing remote refs (e.g. a matching push).

   function Discover_Ssh (Url : String) return Discovery_Result;
   --  As Discover_Http, over SSH receive-pack.

end Version.Receive_Pack;
