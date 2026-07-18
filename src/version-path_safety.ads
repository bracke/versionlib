with Ada.Containers.Indefinite_Vectors;

package Version.Path_Safety is

   package Path_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type   => Natural,
      Element_Type => String);

   subtype Path_Vector is Path_Vectors.Vector;

   function Is_Safe_Relative_Path
     (Path : String)
      return Boolean;

   procedure Require_Safe_Relative_Path
     (Path          : String;
      Context       : String := "path";
      Allow_Control : Boolean := False);
   --  Allow_Control permits control characters other than NUL. git allows
   --  them in tree entry and index paths (a tab in a filename is a legal
   --  POSIX name it happily stores and lists), so read paths must not reject
   --  them; write paths keep the stricter default.

   function Normalize_Relative_Path
     (Path          : String;
      Allow_Control : Boolean := False)
      return String;

   function Is_Windows_Safe_Relative_Path
     (Path : String)
      return Boolean;

   procedure Require_Windows_Safe_Relative_Path
     (Path    : String;
      Context : String := "path");

   procedure Check_Case_Collisions
     (Paths            : Path_Vector;
      Case_Insensitive : Boolean := True);

end Version.Path_Safety;
