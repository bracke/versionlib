with Ada.Streams;

with Http_Client.Response_Streams;

package Version.Transport.Http is

   --  Receives raw bytes from a Git HTTP response body.
   --
   --  Implementations must treat Data as binary, not text. The HTTP
   --  transport deliberately exposes Ada.Streams.Stream_Element_Array so
   --  pkt-line, pack, and side-band protocol phases can consume bytes
   --  without UTF conversion or line-ending normalization.
   type Byte_Consumer is limited interface;

   procedure Consume
     (Item : in out Byte_Consumer;
      Data : Ada.Streams.Stream_Element_Array) is abstract;
   --  Consume one non-empty chunk of response body bytes.

   function Upload_Pack_Info_Refs_Url
     (Base_Url : String)
      return String;

   function Receive_Pack_Info_Refs_Url
     (Base_Url : String)
      return String;
   --  Return Base_Url with the Git receive-pack discovery suffix appended.
   --  Existing .git suffixes are preserved and trailing slashes are removed
   --  before appending /info/refs?service=git-receive-pack.

   function Git_Streaming_Options
      return Http_Client.Response_Streams.Streaming_Options;
   --  Return the common HttpClient streaming options used for Git smart HTTP.
   --  HTTPS requests prefer HTTP/2 through ALPN with HTTP/1.1 fallback; plain
   --  HTTP remains HTTP/1.1 because h2c is not supported by the backend.

   --  On an HTTP 401 the transport runs `credential fill` (using the current
   --  repository's `credential.helper` config), retries the request with HTTP
   --  Basic authentication, and `credential approve`/`reject`s the result
   --  (git's smart-HTTP auth flow). URL userinfo (`user[:pass]@host`) is
   --  honoured for pre-emptive authentication.

   --  A plain GET, for the dumb protocol (`http-fetch` walks loose objects
   --  and packs over ordinary requests).  Found comes back False when the
   --  server has no such file -- a missing loose object is how the walker
   --  learns to go look in the packs -- rather than raising.
   procedure Get
     (Url      : String;
      Consumer : in out Byte_Consumer'Class;
      Found    : out Boolean);

   procedure Discover_Upload_Pack
     (Url      : String;
      Consumer : in out Byte_Consumer'Class);
   --  Issue a Git-safe streaming discovery request for git-upload-pack and
   --  feed the raw response body to Consumer. This is a transport primitive
   --  only; it does not parse pkt-lines, capabilities, refs, or packs.

   procedure Upload_Pack
     (Url      : String;
      Request  : Ada.Streams.Stream_Element_Array;
      Consumer : in out Byte_Consumer'Class);
   --  POST a git-upload-pack request and stream the raw response body to
   --  Consumer. Request is binary pkt-line data and is sent without text
   --  normalization.

   procedure Discover_Receive_Pack
     (Url      : String;
      Consumer : in out Byte_Consumer'Class);
   --  Issue git-receive-pack info/refs discovery.

   procedure Receive_Pack
     (Url      : String;
      Request  : Ada.Streams.Stream_Element_Array;
      Consumer : in out Byte_Consumer'Class);
   --  POST a git-receive-pack request and stream the raw response body.

end Version.Transport.Http;
