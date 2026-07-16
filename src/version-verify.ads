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

   type Signature_Details_Result is record
      Present     : Boolean := False;                --  object carries a sig
      Code        : Character := 'N';                --  git %G?
      Signer      : Ada.Strings.Unbounded.Unbounded_String;   --  %GS
      Key         : Ada.Strings.Unbounded.Unbounded_String;   --  %GK
      Fingerprint : Ada.Strings.Unbounded.Unbounded_String;   --  %GF
      Primary_FP  : Ada.Strings.Unbounded.Unbounded_String;   --  %GP
      Trust       : Ada.Strings.Unbounded.Unbounded_String;   --  %GT
      Raw_Output  : Ada.Strings.Unbounded.Unbounded_String;   --  %GG
   end record;

   function Signature_Details
     (Repo : Version.Repository.Repository_Handle;
      Id   : Version.Objects.Hex_Object_Id)
      return Signature_Details_Result;
   --  Parse gpg's --status-fd tokens for the signed object into git's
   --  %G?/%GS/%GK/%GF/%GP/%GT/%GG fields. For an unsigned object the result is
   --  Present=False, Code='N', Trust="undefined" and empty text fields.

end Version.Verify;
