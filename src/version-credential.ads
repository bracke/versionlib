with Ada.Strings.Unbounded;
with Version.Repository;

package Version.Credential is
   --  The git credential-helper protocol: `credential.helper` values name
   --  helper programs that are queried for a username/password on `get`, told
   --  to remember them on `store`, and to forget them on `erase`. Mirrors
   --  `git credential fill/approve/reject`.

   use Ada.Strings.Unbounded;

   type Credential is record
      Protocol : Unbounded_String;
      Host     : Unbounded_String;
      Path     : Unbounded_String;
      Username : Unbounded_String;
      Password : Unbounded_String;
   end record;

   function Serialize (Cred : Credential) return String;
   --  Render as git's key=value lines terminated by a blank line.

   procedure Parse (Text : String; Cred : in out Credential);
   --  Merge the key=value lines in Text into Cred (unknown keys ignored).

   procedure Fill
     (Repo : Version.Repository.Repository_Handle;
      Cred : in out Credential);
   --  Query each configured helper with "get" until username and password are
   --  both known, merging each helper's reply into Cred.

   procedure Approve
     (Repo : Version.Repository.Repository_Handle;
      Cred : Credential);
   --  Offer the credential to each helper with "store".

   procedure Reject
     (Repo : Version.Repository.Repository_Handle;
      Cred : Credential);
   --  Tell each helper to "erase" the credential.

end Version.Credential;
