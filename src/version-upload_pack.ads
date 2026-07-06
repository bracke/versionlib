with Ada.Containers.Vectors;
with Ada.Streams;
with Ada.Strings.Unbounded;

with Version.Hash;
with Version.Objects;
with Version.Transport.Http;

package Version.Upload_Pack is

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
      Head_Target  : Unbounded_String;
   end record;

   function Parse_Discovery
     (Data : Ada.Streams.Stream_Element_Array)
      return Discovery_Result;
   --  Parse a smart HTTP git-upload-pack discovery advertisement. The
   --  parser accepts protocol v0/v1 advertisements with the service header,
   --  service flush, advertised refs, first-ref NUL capabilities, and symref
   --  HEAD capability.

   function Parse_Advertisement
     (Data : Ada.Streams.Stream_Element_Array)
      return Discovery_Result;
   --  Parse a raw git-upload-pack advertisement as produced by SSH
   --  transport.  Unlike smart HTTP discovery, this form starts directly
   --  with advertised refs and has no service header packet.

   function Default_Branch_From_Advertisements
     (Refs : Advertised_Ref_Vectors.Vector)
      return String;
   --  Select the default branch from advertised upload-pack refs.  HEAD is
   --  matched by object id against refs/heads/*; ties prefer main, master,
   --  then the lexicographically first branch.  Without an advertised HEAD,
   --  the same main/master/lexicographic fallback is used.  Raises
   --  Data_Error when no branch refs are advertised.

   function Has_Capability
     (Capabilities : String;
      Name         : String)
      return Boolean;
   --  Return True when Name appears as an exact upload-pack capability token.

   function Advertised_Object_Format
     (Capabilities : String)
      return Version.Hash.Hash_Algorithm;
   --  The object format from a capability advertisement's "object-format="
   --  token: Sha256 when it is exactly "sha256", otherwise Sha1 (the default
   --  when the capability is absent).

   function Build_Want_Request
     (Want_Id     : Version.Objects.Hex_Object_Id;
      Include_Tag : Boolean := False)
      return Ada.Streams.Stream_Element_Array;

   function Build_Want_Request
     (Want_Id     : Version.Objects.Hex_Object_Id;
      Filter_Spec : String;
      Include_Tag : Boolean := False)
      return Ada.Streams.Stream_Element_Array;

   function Build_Want_Request
     (Want_Id     : Version.Objects.Hex_Object_Id;
      Depth       : Positive;
      Include_Tag : Boolean := False)
      return Ada.Streams.Stream_Element_Array;
   --  Build a conservative upload-pack request. Include_Tag requests
   --  annotated tag objects for fetched commits when the server advertised
   --  that capability. Filter_Spec emits a protocol v0 filter line such as
   --  blob:none and must only be used when the server advertised filter.

   type Shallow_Update is record
      Shallow   : Version.Objects.Object_Id_Vectors.Vector;
      Unshallow : Version.Objects.Object_Id_Vectors.Vector;
   end record;

   function Parse_Shallow_Update
     (Data : Ada.Streams.Stream_Element_Array)
      return Shallow_Update;

   procedure Parse_Shallow_Line
     (Payload : String;
      Update  : in out Shallow_Update;
      Matched : out Boolean);
   --  Parse one textual shallow/unshallow pkt-line payload into Update.
   --  Matched is False for non-shallow protocol packets such as ACK/NAK or
   --  side-band data. This helper lets streaming demuxers process shallow
   --  metadata without materializing the complete upload-pack response.

   procedure Demux_Response
     (Data     : Ada.Streams.Stream_Element_Array;
      Consumer : in out Version.Transport.Http.Byte_Consumer'Class);

   procedure Demux_Response
     (Data     : Ada.Streams.Stream_Element_Array;
      Consumer : in out Version.Transport.Http.Byte_Consumer'Class;
      Update   : out Shallow_Update);
   --  Consume an upload-pack response. NAK and ACK packets are accepted,
   --  side-band channel 1 bytes are forwarded to Consumer, channel 2 is
   --  ignored, and channel 3 raises Data_Error.

end Version.Upload_Pack;
