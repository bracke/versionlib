with Version.Hash;
with Version.Objects;
with Version.Repository;

package Version.Fetch is

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
