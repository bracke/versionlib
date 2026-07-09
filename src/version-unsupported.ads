package Version.Unsupported is
   --  SHA-256 (extensions.objectFormat = sha256) is a supported object format;
   --  Object_Format only names genuinely unsupported formats (anything that is
   --  neither sha1 nor sha256).
   function Object_Format (Format : String) return String is
     ("unsupported repository object format: " & Format);

   function Promisor_Objects return String is
     ("unsupported promisor object: no configured partial-clone promisor remote");

   function Ref_Storage (Storage : String) return String is
     ("unsupported repository ref storage: " & Storage);

   function Http_3 return String is
     ("unsupported transport feature: HTTP/3 backend is not available");

   function H2C return String is
     ("unsupported transport feature: h2c upgrade is not supported");

   function Server_Push return String is
     ("unsupported transport feature: server push is not supported");

   function Remote_Url return String is
     ("unsupported remote URL: expected local path, file://, http(s) smart transport, "
      & "or configured SSH transport");
end Version.Unsupported;
