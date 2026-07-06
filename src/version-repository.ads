with Ada.Strings.Unbounded;

with Version.Hash;

package Version.Repository is

   type Repository_Handle is private;

   function Open return Repository_Handle;

   function Open_Git_Dir
     (Git_Dir : String) return Repository_Handle;

   function Root_Path
     (Repo : Repository_Handle)
      return String;

   function Git_Dir
     (Repo : Repository_Handle)
      return String;

   function Common_Git_Dir
     (Repo : Repository_Handle)
      return String;

   function Resolve_Git_Dir
     (Working_Path : String)
      return String;

   function Is_Linked_Worktree
     (Repo : Repository_Handle)
      return Boolean;

   function Algorithm
     (Repo : Repository_Handle)
      return Version.Hash.Hash_Algorithm;
   --  The object-id hash algorithm for this repository, read from
   --  extensions.objectFormat at Open time (Sha1 by default).

private

   use Ada.Strings.Unbounded;

   type Repository_Handle is record
      Root_Path_Value : Unbounded_String;
      Git_Dir_Value        : Unbounded_String;
      Common_Git_Dir_Value : Unbounded_String;
      Algorithm_Value      : Version.Hash.Hash_Algorithm := Version.Hash.Sha1;
   end record;

end Version.Repository;
