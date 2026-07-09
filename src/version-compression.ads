package Version.Compression is

   function Inflate_Zlib
     (Input : String)
      return String;

   function Deflate_Zlib
     (Input : String)
      return String;

   function Gzip
     (Input : String)
      return String;
   --  Encode Input as a single deterministic gzip member (used for
   --  `archive --format=tar.gz`). Any standard gunzip/git can decompress it.

end Version.Compression;
