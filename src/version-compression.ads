package Version.Compression is

   function Inflate_Zlib
     (Input : String)
      return String;

   function Deflate_Zlib
     (Input : String)
      return String;

end Version.Compression;
