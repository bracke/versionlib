package Version.Transport is

   type Transport_Kind is
     (Local_Transport,
      Http_Transport,
      Ssh_Transport,
      Unsupported_Transport);

   function Detect_Transport (Url : String) return Transport_Kind;

   procedure Require_Supported_Url (Url : String);

   function Strip_File_Scheme (Url : String) return String;

end Version.Transport;
