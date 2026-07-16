with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Version.Repository;

--  The `.gitattributes` engine: what attributes apply to a path.
--
--  git consults, from lowest precedence to highest: `core.attributesFile`,
--  then `$GIT_DIR/info/attributes`, then a `.gitattributes` in each directory
--  from the repository root down to the path's own directory -- the deepest
--  file wins, and within one file the last matching line wins.  A `[attr]NAME`
--  line defines a macro; `binary` is built in (`-diff -merge -text`).
package Version.Attributes is

   use Ada.Strings.Unbounded;

   type Attribute_State is
     (Attribute_Set,          --  `text`
      Attribute_Unset,        --  `-text`
      Attribute_Unspecified,  --  `!text`, or never mentioned
      Attribute_Valued);      --  `text=auto`

   type Attribute_Result is record
      State : Attribute_State := Attribute_Unspecified;
      Value : Unbounded_String;
   end record;

   type Named_Attribute is record
      Name   : Unbounded_String;
      Result : Attribute_Result;
   end record;

   package Named_Attribute_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Named_Attribute);

   --  What Name is for Path (a repository-relative path, which need not
   --  exist).
   function Lookup
     (Repo : Version.Repository.Repository_Handle;
      Path : String;
      Name : String)
      return Attribute_Result;

   --  Every attribute that Path has (`check-attr -a`): the ones that are set,
   --  unset, or valued, in git's registration order -- the built-in macro's
   --  `diff`, `merge`, `text` first, then the rest as the attribute files
   --  mention them.
   function All_For_Path
     (Repo : Version.Repository.Repository_Handle;
      Path : String)
      return Named_Attribute_Vectors.Vector;

   function State_Image (Result : Attribute_Result) return String;
   --  git's rendering: "set", "unset", "unspecified", or the value itself.

end Version.Attributes;
