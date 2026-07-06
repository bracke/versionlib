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

   procedure Disable
     (Repo : Version.Repository.Repository_Handle);

   function Included
     (Repo         : Version.Repository.Repository_Handle;
      Path         : String;
      Is_Directory : Boolean := False)
      return Boolean;

end Version.Sparse;
