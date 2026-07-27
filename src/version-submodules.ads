with Ada.Containers.Vectors;
with Ada.Containers.Indefinite_Vectors;
with Ada.Strings.Unbounded;

with Version.Objects;
with Version.Repository;

package Version.Submodules is

   use Ada.Strings.Unbounded;

   package Path_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type   => Natural,
      Element_Type => String);

   type Submodule_Status_Kind is
     (Submodule_Missing,
      Submodule_Clean,
      Submodule_New_Commits,
      Submodule_Dirty);

   type Submodule_Status is record
      Path     : Unbounded_String;
      Expected : Version.Objects.Object_Id_Storage;
      Actual   : Unbounded_String;
      Kind     : Submodule_Status_Kind;
   end record;

   package Submodule_Status_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Submodule_Status);

   procedure Add
     (Repo   : Version.Repository.Repository_Handle;
      Url    : String;
      Path   : String;
      Branch : String := "";
      Name   : String := "";
      Force  : Boolean := False);
   --  git's `submodule add`: clone Url into Path, record it in .gitmodules,
   --  stage both that file and the gitlink, and register the resolved URL in
   --  the local config. The URL is stored in .gitmodules exactly as given --
   --  a relative one stays relative, which is what makes the superproject
   --  portable -- while the config holds the resolved form used to fetch.
   --
   --  Branch is `-b`: the submodule is left on that branch and it is recorded
   --  in .gitmodules. Name is `--name`: the submodule's logical name, which
   --  defaults to Path and keys both the config and the administrative
   --  directory, so the two part company once it is given. Force is `-f`,
   --  which lets an already-registered path be recorded again.
   --
   --  A Path that is already a repository is adopted rather than cloned over,
   --  as git does; only a non-repository directory in the way is an error.

   procedure Init
     (Paths : Path_Vectors.Vector := Path_Vectors.Empty_Vector);

   procedure Init
     (Repo  : Version.Repository.Repository_Handle;
      Paths : Path_Vectors.Vector := Path_Vectors.Empty_Vector);

   procedure Update
     (Recursive    : Boolean := False;
      Init_Missing : Boolean := False;
      Paths        : Path_Vectors.Vector := Path_Vectors.Empty_Vector);

   procedure Update
     (Repo         : Version.Repository.Repository_Handle;
      Recursive    : Boolean := False;
      Init_Missing : Boolean := False;
      Paths        : Path_Vectors.Vector := Path_Vectors.Empty_Vector);

   procedure Clone_Recursive
     (Url    : String;
      Target : String);

   procedure Status;

   --  git's `submodule summary`: for each submodule whose checked-out HEAD
   --  differs from the recorded gitlink, print a "* <path> <a>...<b> (<n>):"
   --  header followed by the differing commits' subjects ("< " removed by the
   --  move, "> " added), and a trailing blank line.
   procedure Summary;

   procedure Summary (Repo : Version.Repository.Repository_Handle);

   --  Run a shell command in each populated (active) submodule working tree,
   --  matching `git submodule foreach`. Prints "Entering '<path>'" and exposes
   --  $name, $sm_path, $displaypath, $sha1 and $toplevel to the command; stops
   --  (raises) if a command exits non-zero.
   procedure Foreach
     (Command   : String;
      Recursive : Boolean := False;
      Quiet     : Boolean := False);

   procedure Foreach
     (Repo      : Version.Repository.Repository_Handle;
      Command   : String;
      Recursive : Boolean := False;
      Quiet     : Boolean := False);

   --  Copy each submodule's `.gitmodules` URL into the superproject's
   --  .git/config (submodule.<name>.url) and the submodule's own
   --  remote.origin.url, matching `git submodule sync`.
   procedure Sync
     (Recursive : Boolean := False;
      Paths     : Path_Vectors.Vector := Path_Vectors.Empty_Vector);

   procedure Sync
     (Repo      : Version.Repository.Repository_Handle;
      Recursive : Boolean := False;
      Paths     : Path_Vectors.Vector := Path_Vectors.Empty_Vector);

   --  Unregister submodules: empty their working trees and remove their
   --  submodule.<name>.* config from the superproject's .git/config (keeping
   --  the .gitmodules entry), matching `git submodule deinit`.
   procedure Deinit
     (Paths          : Path_Vectors.Vector;
      All_Submodules : Boolean := False;
      Force          : Boolean := False);

   procedure Deinit
     (Repo           : Version.Repository.Repository_Handle;
      Paths          : Path_Vectors.Vector;
      All_Submodules : Boolean := False;
      Force          : Boolean := False);

   function Statuses
     (Repo : Version.Repository.Repository_Handle)
      return Submodule_Status_Vectors.Vector;

   function Status_Kind_Label
     (Kind : Submodule_Status_Kind)
      return String;

   function Status_Line
     (Item : Submodule_Status)
      return String;

   --  git's `submodule status` line for one submodule:
   --  "<prefix><sha> <path>[ (<describe>)]".  The sha is the checked-out
   --  commit, or the index-recorded one when Cached; a not-checked-out
   --  submodule is "-<sha> <path>" with no describe.  The describe is git's
   --  `--all --always` computed inside the submodule (a ref name like
   --  "heads/main"/"tags/v2", else the short id).
   function Status_Line_Git
     (Repo   : Version.Repository.Repository_Handle;
      Item   : Submodule_Status;
      Cached : Boolean := False)
      return String;

   function Gitlink_Commit
     (Repo : Version.Repository.Repository_Handle;
      Path : String)
      return Version.Objects.Hex_Object_Id;

   function Is_Submodule_Path
     (Repo : Version.Repository.Repository_Handle;
      Path : String)
      return Boolean;

   function Submodule_Head
     (Repo : Version.Repository.Repository_Handle;
      Path : String)
      return String;

   procedure Stage_Submodule
     (Repo : Version.Repository.Repository_Handle;
      Path : String);

   function Resolve_Relative_Submodule_Url
     (Relative_Url : String;
      Base_Url     : String)
      return String;

end Version.Submodules;
