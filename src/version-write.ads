with Version.Objects;
with Version.Repository;
with Version.Staging;

package Version.Write is

   function Write_Blob
     (Repo    : Version.Repository.Repository_Handle;
      Content : String)
      return Version.Objects.Hex_Object_Id;

   --  Write a loose object of an arbitrary kind ("blob", "tree", "commit",
   --  "tag") from its exact payload bytes, returning its id. Used by `mktag`
   --  to store a caller-supplied tag object verbatim.
   function Write_Object
     (Repo    : Version.Repository.Repository_Handle;
      Kind    : String;
      Content : String)
      return Version.Objects.Hex_Object_Id;

   procedure Copy_Object
     (Source : Version.Repository.Repository_Handle;
      Target : Version.Repository.Repository_Handle;
      Id     : Version.Objects.Hex_Object_Id);
   --  Copy a single object verbatim from Source to Target as a loose object,
   --  preserving its id (used by partial-clone selective object copy).

   function Write_Tree_From_Index
     (Repo    : Version.Repository.Repository_Handle;
      Entries : Version.Staging.Index_Entry_Vectors.Vector)
      return Version.Objects.Hex_Object_Id;

   --  Write a single-level tree object from explicit entries (as `git mktree`
   --  does). Each entry's Mode is the git file mode ("100644", "40000", ...),
   --  Path is the entry name, Id its object id, and Kind selects the tree/blob/
   --  gitlink sort semantics. Entries are canonicalised (leading-zero modes
   --  trimmed) and sorted into git tree order before serialisation; the tree is
   --  written loose and its id returned.
   function Write_Tree
     (Repo    : Version.Repository.Repository_Handle;
      Entries : Version.Objects.Tree_Entry_Vectors.Vector)
      return Version.Objects.Hex_Object_Id;

   function Write_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Tree_Id   : Version.Objects.Hex_Object_Id;
      Parent_Id : String;
      Message   : String)
      return Version.Objects.Hex_Object_Id;

   function Write_Commit_With_Parents
     (Repo    : Version.Repository.Repository_Handle;
      Tree_Id : Version.Objects.Hex_Object_Id;
      Parents : Version.Objects.Object_Id_Vectors.Vector;
      Message : String)
      return Version.Objects.Hex_Object_Id;

   function Write_Commit_With_Author
     (Repo    : Version.Repository.Repository_Handle;
      Tree_Id : Version.Objects.Hex_Object_Id;
      Parents : Version.Objects.Object_Id_Vectors.Vector;
      Author  : String;
      Message : String)
      return Version.Objects.Hex_Object_Id;
   --  Like Write_Commit_With_Parents but with an explicit author line value
   --  ("Name <email> <ts> <tz>"); the committer is the configured identity.
   --  Used by `am` to preserve a patch's authorship.

   function Write_Commit_Raw
     (Repo      : Version.Repository.Repository_Handle;
      Tree_Id   : Version.Objects.Hex_Object_Id;
      Parents   : Version.Objects.Object_Id_Vectors.Vector;
      Author    : String;
      Committer : String;
      Message   : String)
      return Version.Objects.Hex_Object_Id;
   --  Write a commit with explicit, verbatim author and committer lines
   --  ("Name <email> <ts> <tz>"), preserving both identities and their
   --  timestamps. Used by `lfs migrate` to rewrite history faithfully.

   function Write_Signed_Commit_With_Parents
     (Repo        : Version.Repository.Repository_Handle;
      Tree_Id     : Version.Objects.Hex_Object_Id;
      Parents     : Version.Objects.Object_Id_Vectors.Vector;
      Message     : String;
      Signing_Key : String)
      return Version.Objects.Hex_Object_Id;

   function Write_Tag
     (Repo        : Version.Repository.Repository_Handle;
      Target_Id   : Version.Objects.Hex_Object_Id;
      Tag_Name    : String;
      Message     : String;
      Signing_Key : String := "")
      return Version.Objects.Hex_Object_Id;
   --  When Signing_Key is non-empty the tag payload is signed with gpg and the
   --  ASCII-armored PGP signature is appended after the message (git `tag -s`
   --  / `tag -u <key>`; "default" uses the default gpg key).

   type Sign_Choice is (Sign_From_Config, Sign_Force, Sign_Disable);
   --  How a new commit's OpenPGP signature is decided:
   --    * Sign_From_Config -- honour commit.gpgSign (git's default);
   --    * Sign_Force       -- always sign (CLI `-S` / `--gpg-sign`);
   --    * Sign_Disable     -- never sign (CLI `--no-gpg-sign`).
   --  A non-empty Signing_Key implies signing even under Sign_From_Config.

   procedure Save_Amend
     (Message     : String;
      Run_Hooks   : Boolean := True;
      Sign        : Sign_Choice := Sign_From_Config;
      Signing_Key : String := "");

   procedure Save
     (Message     : String;
      Run_Hooks   : Boolean := True;
      Sign        : Sign_Choice := Sign_From_Config;
      Signing_Key : String := "");

end Version.Write;