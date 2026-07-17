with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Version.Repository;

package Version.Config is

   use Ada.Strings.Unbounded;

   --  Raised by the single-value Unset_* operations when the key resolves to
   --  more than one value; git refuses such an unset (exit 5) and leaves the
   --  file untouched rather than dropping every value.
   Ambiguous_Key : exception;

   --  Raised by Unset_* when the key is not present at all; git treats this
   --  as exit 5 with no diagnostic (nothing to unset).
   Key_Absent : exception;

   type Identity is record
      Name  : Unbounded_String;
      Email : Unbounded_String;
   end record;

   type Config_Entry is record
      Section : Unbounded_String;
      Key     : Unbounded_String;
      Value   : Unbounded_String;
   end record;

   package Config_Entry_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Config_Entry);

   function User_Identity
     (Repo : Version.Repository.Repository_Handle)
      return Identity;

   --  The "Name <email> <seconds> <+-hhmm>" line a new commit records.  git
   --  lets the environment override every part of it -- GIT_AUTHOR_NAME,
   --  GIT_AUTHOR_EMAIL and GIT_AUTHOR_DATE (and the GIT_COMMITTER_* trio) win
   --  over the configured identity and the current time, which is what makes
   --  a commit's object id reproducible.  An absent date means "now", in the
   --  local timezone, as git records it.
   function Author_Signature
     (Repo : Version.Repository.Repository_Handle)
      return String;

   function Committer_Signature
     (Repo : Version.Repository.Repository_Handle)
      return String;

   --  Normalise one of git's accepted date spellings to git's own
   --  "<seconds> <+-hhmm>".  Returns "" if Text is not a date we understand.
   function Normalize_Date (Text : String) return String;

   --  The "<seconds> <+-hhmm>" a new reflog entry is stamped with: what
   --  GIT_COMMITTER_DATE says, or now in the local timezone.
   function Committer_Timestamp return String;

   function Trim
     (Value : String)
      return String;

   procedure Require_Config_Scalar
     (Value   : String;
      Context : String);

   procedure Require_Config_Key
     (Key     : String;
      Context : String := "config key");

   procedure Require_Config_Section
     (Section : String;
      Context : String := "config section");

   function Read_All
     (Repo : Version.Repository.Repository_Handle)
      return Config_Entry_Vectors.Vector;

   function Config_Entry_Name
     (Current_Entry : Config_Entry)
      return String;

   function Config_Entry_Line
     (Current_Entry : Config_Entry)
      return String;

   function Get_Value
     (Repo : Version.Repository.Repository_Handle;
      Name : String)
      return String;

   function Get_Text
     (Repo : Version.Repository.Repository_Handle;
      Name : String)
      return String;

   function Has_Key
     (Repo : Version.Repository.Repository_Handle;
      Name : String)
      return Boolean;

   procedure Set_Key
     (Repo  : Version.Repository.Repository_Handle;
      Name  : String;
      Value : String);

   procedure Unset_Key
     (Repo : Version.Repository.Repository_Handle;
      Name : String);

   procedure Set_Key_Worktree
     (Repo  : Version.Repository.Repository_Handle;
      Name  : String;
      Value : String);
   --  Like Set_Key, but targets $GIT_DIR/config.worktree when
   --  extensions.worktreeConfig is enabled; otherwise the common config
   --  (git's --worktree fallback semantics).

   procedure Unset_Key_Worktree
     (Repo : Version.Repository.Repository_Handle;
      Name : String);

   function Worktree_Config_Active
     (Repo : Version.Repository.Repository_Handle) return Boolean;
   --  True when extensions.worktreeConfig is enabled in the common config.

   function List_Text
     (Repo : Version.Repository.Repository_Handle)
      return String;

   function Keys_Text
     (Repo : Version.Repository.Repository_Handle)
      return String;

   procedure Replace_Section
     (Repo    : Version.Repository.Repository_Handle;
      Section : String;
      Entries : Config_Entry_Vectors.Vector);

   procedure Remove_Section
     (Repo    : Version.Repository.Repository_Handle;
      Section : String);

end Version.Config;