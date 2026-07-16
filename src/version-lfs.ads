private with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;
with Version.Objects;
with Version.Repository;

package Version.LFS is

   function Clean_Content
     (Repo          : Version.Repository.Repository_Handle;
      Relative_Path : String;
      Content       : String)
      return String;

   function Smudge_Content
     (Repo          : Version.Repository.Repository_Handle;
      Relative_Path : String;
      Content       : String)
      return String;

   function Worktree_Content
     (Repo          : Version.Repository.Repository_Handle;
      Relative_Path : String;
      Content       : String)
      return String;

   function Upload_Object
     (Repo        : Version.Repository.Repository_Handle;
      Oid         : String;
      Remote_Name : String)
      return Boolean;
   --  Upload the locally-cached LFS object Oid to the configured LFS store
   --  (lfs.url, else remote.<Remote_Name>.url) when that store is a local
   --  directory, storing it under <store>/objects/<oid[0:2]>/<oid[2:4]>/<oid>.
   --  Returns True if the object is present at the destination afterwards
   --  (uploaded or already there); False if the store is not a local directory
   --  (HTTP/SSH upload remains a follow-up) or the object is not cached locally.

   procedure Upload_Referenced_Objects
     (Repo        : Version.Repository.Repository_Handle;
      Commit_Id   : Version.Objects.Hex_Object_Id;
      Remote_Name : String);
   --  Upload every LFS object referenced by an LFS-pointer blob reachable from
   --  Commit_Id (git-lfs pre-push behavior). Objects whose store is not a local
   --  directory, or that are not cached locally, are skipped.

   -----------------------------------------------------------------------------
   --  File locking (git-lfs lock / unlock / locks)
   -----------------------------------------------------------------------------

   type Lock_Info is record
      Id        : Ada.Strings.Unbounded.Unbounded_String;
      Path      : Ada.Strings.Unbounded.Unbounded_String;
      Owner     : Ada.Strings.Unbounded.Unbounded_String;
      Locked_At : Ada.Strings.Unbounded.Unbounded_String;
      Owned     : Boolean := False;
      --  Owned is True when the lock belongs to the authenticated user
      --  (git-lfs "ours"); only populated by List_Locks with Verify => True.
   end record;

   type Lock_Array is array (Positive range <>) of Lock_Info;

   function Create_Lock
     (Repo        : Version.Repository.Repository_Handle;
      Path        : String;
      Remote_Name : String := "origin")
      return Lock_Info;
   --  Create a lock for Path on the configured LFS store's lock server
   --  (lfs.url, else remote.<Remote_Name>.url; SSH remotes are reached via
   --  git-lfs-authenticate, or the pure-SSH git-lfs-transfer lock verb).
   --  Raises Ada.IO_Exceptions.Use_Error on conflict (already locked) or when
   --  no lock server can be reached.

   function List_Locks
     (Repo        : Version.Repository.Repository_Handle;
      Remote_Name : String := "origin";
      Path        : String := "";
      Id          : String := "";
      Verify      : Boolean := False)
      return Lock_Array;
   --  List active locks, optionally filtered by Path or Id. With Verify, the
   --  server is asked to partition locks into ours/theirs and Lock_Info.Owned
   --  is set accordingly.

   procedure Delete_Lock
     (Repo        : Version.Repository.Repository_Handle;
      Id          : String := "";
      Path        : String := "";
      Force       : Boolean := False;
      Remote_Name : String := "origin");
   --  Release a lock identified by Id, or by Path (resolved to an id via
   --  List_Locks). Force releases a lock owned by another user. Raises
   --  Ada.IO_Exceptions.Use_Error when the lock cannot be found or released.

   -----------------------------------------------------------------------------
   --  Porcelain support (git-lfs track / ls-files / status / fetch / pointer)
   -----------------------------------------------------------------------------

   type Pointer_Info is record
      Is_Pointer : Boolean := False;
      Oid        : Ada.Strings.Unbounded.Unbounded_String;
      Size       : Natural := 0;
   end record;

   function Parse_Pointer (Content : String) return Pointer_Info;
   --  Recognize an LFS pointer blob and extract its oid and byte size.

   function Build_Pointer (Content : String) return String;
   --  The LFS pointer text for arbitrary media Content (sha256 + byte size),
   --  as `git lfs pointer --file` produces it, independent of tracking.

   function Is_Tracked
     (Repo          : Version.Repository.Repository_Handle;
      Relative_Path : String) return Boolean;
   --  True when Relative_Path is covered by a filter=lfs .gitattributes rule.

   function Object_Cached
     (Repo : Version.Repository.Repository_Handle;
      Oid  : String) return Boolean;
   --  True when the media for Oid is present in the local LFS object cache.

   function Object_Corrupt
     (Repo : Version.Repository.Repository_Handle;
      Oid  : String) return Boolean;
   --  True when the cached media for Oid exists but its sha256 does not match
   --  Oid (git lfs fsck). A valid cached object, or an absent one, is False.

   function Fetch_Object
     (Repo          : Version.Repository.Repository_Handle;
      Oid           : String;
      Expected_Size : Natural) return Boolean;
   --  Ensure the media for Oid is in the local cache, downloading it from the
   --  configured LFS store (lfs.url, else remote.origin.url) when absent.
   --  True if present afterwards (already cached or fetched).

   type Pattern_Entry is record
      Pattern : Ada.Strings.Unbounded.Unbounded_String;
      Source  : Ada.Strings.Unbounded.Unbounded_String;
   end record;
   type Pattern_Array is array (Positive range <>) of Pattern_Entry;

   function Tracked_Patterns
     (Repo : Version.Repository.Repository_Handle) return Pattern_Array;
   --  The filter=lfs patterns declared in the working tree's .gitattributes
   --  and .git/info/attributes, each tagged with the file it came from.

   function Track_Pattern
     (Repo : Version.Repository.Repository_Handle; Pattern : String)
      return Boolean;
   --  Append an LFS tracking rule for Pattern to the working tree's
   --  .gitattributes (creating it). False if Pattern is already tracked.

   function Untrack_Pattern
     (Repo : Version.Repository.Repository_Handle; Pattern : String)
      return Boolean;
   --  Remove the LFS tracking rule for Pattern. False if it was not tracked.

   type LFS_Entry is record
      Path   : Ada.Strings.Unbounded.Unbounded_String;
      Oid    : Ada.Strings.Unbounded.Unbounded_String;
      Size   : Natural := 0;
      Cached : Boolean := False;
   end record;
   type LFS_Entry_Array is array (Positive range <>) of LFS_Entry;

   function LFS_Entries_In_Index
     (Repo : Version.Repository.Repository_Handle) return LFS_Entry_Array;
   --  The LFS-pointer files recorded in the index, with oid/size and whether
   --  the media is cached locally.

   function LFS_Entries_In_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id) return LFS_Entry_Array;
   --  As above, for the tree of Commit_Id.

   function LFS_Entries_All_Refs
     (Repo : Version.Repository.Repository_Handle) return LFS_Entry_Array;
   --  LFS entries referenced by the tip of every branch and tag, deduped by
   --  oid (git lfs fetch --all).

   -----------------------------------------------------------------------------
   --  Maintenance and history rewriting (git-lfs prune / migrate)
   -----------------------------------------------------------------------------

   procedure Prune
     (Repo          : Version.Repository.Repository_Handle;
      Dry_Run       : Boolean;
      Total_Objects : out Natural;
      Retained      : out Natural);
   --  Delete cached LFS objects not referenced by any branch/tag tip or the
   --  index (kept objects are "retained"); Dry_Run reports without deleting.

   type Migrate_Direction is (Migrate_Import, Migrate_Export);

   procedure Migrate
     (Repo       : Version.Repository.Repository_Handle;
      Direction  : Migrate_Direction;
      Include    : String;
      Everything : Boolean := False);
   --  Rewrite history, converting blobs matching the comma-separated Include
   --  patterns to (Import) or from (Export) LFS pointers, updating
   --  .gitattributes, the affected branch refs, and the index. Everything
   --  rewrites every local branch; otherwise only HEAD's branch. Author and
   --  committer identities and timestamps are preserved.

   type Migrate_Info_Entry is record
      Name  : Ada.Strings.Unbounded.Unbounded_String;   --  e.g. "*.bin"
      Count : Natural := 0;
      Bytes : Long_Long_Integer := 0;
   end record;
   type Migrate_Info_Array is array (Positive range <>) of Migrate_Info_Entry;

   function Migrate_Info
     (Repo : Version.Repository.Repository_Handle; Everything : Boolean := False)
      return Migrate_Info_Array;
   --  Summarize, by file extension, the blob count and total byte size across
   --  the rewritable history (git lfs migrate info), largest first.

private

   package Lock_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Lock_Info);

end Version.LFS;
