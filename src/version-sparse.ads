with Ada.Containers.Indefinite_Vectors;
with Version.Repository;
with Version.Pathspec;

package Version.Sparse is

   package String_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type   => Natural,
      Element_Type => String);

   function Enabled
     (Repo : Version.Repository.Repository_Handle)
      return Boolean;

   function Patterns
     (Repo : Version.Repository.Repository_Handle)
      return Version.Pathspec.Pathspec_Vectors.Vector;

   function Pattern_Texts
     (Repo : Version.Repository.Repository_Handle)
      return String_Vectors.Vector;

   function Status_Text
     (Repo : Version.Repository.Repository_Handle)
      return String;

   procedure Set
     (Repo     : Version.Repository.Repository_Handle;
      Patterns : Version.Pathspec.Pathspec_Vectors.Vector);

   procedure Set_From_Strings
     (Repo  : Version.Repository.Repository_Handle;
      Items : String_Vectors.Vector);

   --  True when cone mode (core.sparseCheckoutCone) is enabled.
   function Cone_Mode
     (Repo : Version.Repository.Repository_Handle)
      return Boolean;

   --  Enable cone-mode sparse checkout for the given recursively-included
   --  directories: writes git's cone patterns ("/*", "!/*/", "/dir/", and the
   --  ancestor "!/dir/*/" exclusions) to .git/info/sparse-checkout and sets
   --  core.sparseCheckout=true and core.sparseCheckoutCone=true.
   procedure Set_Cone
     (Repo        : Version.Repository.Repository_Handle;
      Directories : String_Vectors.Vector);

   --  The recursively-included (leaf) cone directories, as `git
   --  sparse-checkout list` prints them (sorted, without the ancestor
   --  navigation entries).
   function Cone_Recursive_Directories
     (Repo : Version.Repository.Repository_Handle)
      return String_Vectors.Vector;

   procedure Disable
     (Repo : Version.Repository.Repository_Handle);

   function Included
     (Repo         : Version.Repository.Repository_Handle;
      Path         : String;
      Is_Directory : Boolean := False)
      return Boolean;

end Version.Sparse;
