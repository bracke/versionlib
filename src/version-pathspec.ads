with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

package Version.Pathspec is
   use Ada.Strings.Unbounded;

   type Match_Mode is
     (Literal_Mode,
      Glob_Mode);

   function Empty_Pathspec_Diagnostic return String;
   function Empty_Pathspec_Diagnostic (Text : String) return String;
   function Empty_Component_Diagnostic (Text : String) return String;
   function Current_Directory_Component_Diagnostic (Text : String) return String;
   function Traversal_Component_Diagnostic (Text : String) return String;
   function Git_Dir_Component_Diagnostic (Text : String) return String;
   function Absolute_Pathspec_Diagnostic (Text : String) return String;
   function NUL_Diagnostic return String;
   function Control_Character_Diagnostic return String;
   function Backslash_Separator_Diagnostic (Text : String) return String;
   function Empty_Directory_Diagnostic (Text : String) return String;
   function Unknown_Magic_Diagnostic (Text : String) return String;
   function Empty_Magic_Diagnostic return String;
   function Malformed_Magic_Diagnostic (Text : String) return String;

   type Attribute_Match_Mode is
     (Attribute_Ignored,
      Attribute_Set,
      Attribute_Unset,
      Attribute_Unspecified,
      Attribute_Value);

   type Pathspec_Item is record
      Pattern          : Unbounded_String;
      Mode             : Match_Mode := Literal_Mode;
      Excluded         : Boolean := False;
      Top_Anchored     : Boolean := False;
      Icase            : Boolean := False;
      Directory_Prefix : Boolean := False;
      Has_Slash        : Boolean := False;
      Attribute_Mode   : Attribute_Match_Mode := Attribute_Ignored;
      Attribute_Name   : Unbounded_String;
      Attribute_Value  : Unbounded_String;
   end record;

   package Pathspec_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Pathspec_Item);

   function Parse
     (Text : String)
      return Pathspec_Item;

   procedure Append_Parse
     (Result : in out Pathspec_Vectors.Vector;
      Text   : String);

   function Parse_All
     (Items : Ada.Strings.Unbounded.Unbounded_String)
      return Pathspec_Vectors.Vector;

   function Matches
     (Item         : Pathspec_Item;
      Path         : String;
      Is_Directory : Boolean := False)
      return Boolean;

   function Matches_Any
     (Items        : Pathspec_Vectors.Vector;
      Path         : String;
      Is_Directory : Boolean := False)
      return Boolean;

   function To_Text
     (Item : Pathspec_Item)
      return String;

   function Is_Excluded
     (Item : Pathspec_Item)
      return Boolean;

end Version.Pathspec;
