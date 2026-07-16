with Version.Hash;
with Version.Objects;
with Version.Repository;
with Version.Upload_Pack;

package Version.Fetch is

   --  Every ref the remote advertises (`ls-remote`), in git's order: HEAD
   --  first, then refs sorted by name, an annotated tag followed by its
   --  peeled `^{}` entry.  Remote is a configured remote name, a path, or a
   --  URL.
   function List_Remote_Refs
     (Remote : String)
      return Version.Upload_Pack.Advertised_Ref_Vectors.Vector;

   --  Fetch every object the remote has, updating no local ref -- what
   --  `fetch-pack` does.  Remote is a configured remote name, a path, or a
   --  URL.
   procedure Fetch_Objects_From (Remote : String);

   function Remote_Object_Format
     (Url : String)
      return Version.Hash.Hash_Algorithm;
   --  The object format advertised by (or, for a local source, configured in)
   --  the remote at Url: Sha256 when the remote is a SHA-256 repository, else
   --  Sha1. Used so a clone target is created with the remote's hash width.
   --  Discovery failures fall back to Sha1 (the subsequent fetch surfaces the
   --  real error).

   function Invalid_Packed_Ref_Line_Diagnostic return String;

   function Invalid_Loose_Tag_Object_Id_Diagnostic return String;

   function Invalid_Loose_Branch_Object_Id_Diagnostic return String;

   function Invalid_Packed_Tag_Object_Id_Diagnostic return String;

   function Invalid_Packed_Branch_Object_Id_Diagnostic return String;

   procedure Fetch
     (Remote_Name : String);

   procedure Fetch
     (Remote_Name : String;
      Depth       : Positive);

   --  fetch --deepen N: extend the shallow boundary by N commits relative to
   --  the current boundary (requests the deepen-relative capability). Requires
   --  a smart transport (HTTP/SSH).
   procedure Fetch_Deepen
     (Remote_Name : String;
      Depth       : Positive);

   --  fetch --unshallow: fetch the complete history and remove .git/shallow.
   --  Fails on a repository that is not shallow.
   procedure Fetch_Unshallow
     (Remote_Name : String);

   procedure Fetch
     (Remote_Name : String;
      Filter_Spec : String);
   --  Fetch applying a partial-clone filter spec (e.g. "blob:none" or
   --  "blob:limit=<n>"). Over local transport, version evaluates the filter
   --  directly (selective object copy); over HTTP/SSH the spec is sent when
   --  the server advertises the upload-pack filter capability.

   procedure Fetch_Object
     (Repo        : Version.Repository.Repository_Handle;
      Remote_Name : String;
      Id          : Version.Objects.Hex_Object_Id);
   --  Fetch one promised object from Remote_Name without updating refs.

end Version.Fetch;
