with Ada.Strings.Unbounded;

with Version.Objects;
with Version.Repository;

package Version.Verify is
   --  GPG signature verification for signed commits and annotated tags
   --  (git `verify-commit` / `verify-tag`). The signature is extracted from
   --  the object and handed to `gpg --verify`; gpg's own diagnostics flow to
   --  standard error, matching git's pass-through behavior.

   type Verify_Result is
     (Good_Signature,     --  gpg validated the signature
      Bad_Signature,      --  gpg rejected the signature (or key unavailable)
      No_Signature);      --  the object carries no PGP signature

   function Verify_Object
     (Repo : Version.Repository.Repository_Handle;
      Id   : Version.Objects.Hex_Object_Id)
      return Verify_Result;
   --  Verify the signature of the commit or annotated tag named by Id.

   procedure Verify_Object_Reporting
     (Repo   : Version.Repository.Repository_Handle;
      Id     : Version.Objects.Hex_Object_Id;
      Result : out Verify_Result;
      Output : out Ada.Strings.Unbounded.Unbounded_String);
   --  As Verify_Object, but also capture gpg's own verification text (the
   --  "gpg: Good signature ..." lines) instead of passing it to stderr, for
   --  `log --show-signature`. Output is empty when the object has no signature.

end Version.Verify;
