with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Version.Hash;
with Version.Repository;

package Version.Objects is

   use Ada.Strings.Unbounded;

   --  Object id: a definite, by-value type holding 40 (SHA-1) or 64 (SHA-256)
   --  hex chars. The representation is a fixed buffer + length, so returning
   --  or storing an id costs no secondary-stack/heap allocation — the
   --  unconstrained-`String` form was measured >5x slower on the hot paths
   --  (see docs/SHA256_SCOPE.md). All id <-> text access goes through the
   --  accessor seam below.
   Max_Object_Id_Length : constant := 64;

   --  Representation is exposed only so it can be a by-value container element
   --  and record field; all access should still go through the seam below
   --  (To_String / To_Object_Id / "="/"<"/Id_Length), never the components.
   --  Unused Text bytes are kept canonical (spaces) so predefined "=" is
   --  correct.
   type Object_Id_Storage is record
      Length : Natural range 0 .. Max_Object_Id_Length := 0;
      Text   : String (1 .. Max_Object_Id_Length) := [others => ' '];
   end record;

   subtype Hex_Object_Id is Object_Id_Storage;

   function To_String (Id : Object_Id_Storage) return String;

   function To_Object_Id (Text : String) return Object_Id_Storage;

   function To_Raw (Id : Object_Id_Storage) return String;
   --  The raw (binary) form of a hex object id: 20 bytes for a 40-hex SHA-1
   --  id, 32 bytes for a 64-hex SHA-256 id (each hex pair becomes one byte).

   function To_Hex (Bytes : String) return Hex_Object_Id;
   --  The hex object id for a raw (binary) id: accepts 20 bytes (SHA-1) or
   --  32 bytes (SHA-256). Inverse of To_Raw.

   function Compute_Object_Id
     (Algorithm : Version.Hash.Hash_Algorithm;
      Kind      : String;
      Content   : String)
      return Hex_Object_Id;
   --  The object id of a Git object: Algorithm over "<kind> <size>\0<content>"
   --  (Sha1 -> 40-hex, Sha256 -> 64-hex). The single place object ids are
   --  computed; callers pass their repository's algorithm.

   function Zero_Object_Id return Object_Id_Storage;
   --  The all-zero 40-hex-digit id (git's null object id).

   function Id_Length (Id : Object_Id_Storage) return Natural;

   function "<" (Left, Right : Object_Id_Storage) return Boolean;
   function "=" (Left : Object_Id_Storage; Right : String) return Boolean;
   function "=" (Left : String; Right : Object_Id_Storage) return Boolean;

   type Object_Kind is
     (Blob_Object,
      Tree_Object,
      Commit_Object,
      Tag_Object,
      Unknown_Object);

   type Tree_Entry_Kind is
     (Tree_Blob,
      Tree_Directory,
      Tree_Gitlink);

   type Tree_Entry is record
      Path : Unbounded_String;
      Id   : Object_Id_Storage;
      Kind : Tree_Entry_Kind;
      Mode : Unbounded_String;
   end record;

   package Tree_Entry_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Tree_Entry);

   package Object_Id_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Object_Id_Storage);

   type Git_Object is private;

   function Is_Valid_Hex_Object_Id
     (Value : String)
      return Boolean;

   function Loose_Object_Path
     (Repo : Version.Repository.Repository_Handle;
      Id   : Hex_Object_Id)
      return String;

   function Create_Object
     (Kind    : Object_Kind;
      Content : String)
      return Git_Object;

   function Read_Loose_Object
     (Repo : Version.Repository.Repository_Handle;
      Id   : Hex_Object_Id)
      return Git_Object;

   function Read_Object
     (Repo : Version.Repository.Repository_Handle;
      Id   : Hex_Object_Id)
      return Git_Object;

   function Commit_Tree_Id
     (Obj : Git_Object)
      return Hex_Object_Id;

   function Commit_Parent_Id
     (Obj : Git_Object)
      return String;

   function Commit_Parent_Ids
      (Obj : Git_Object)
         return Object_Id_Vectors.Vector;

   function Commit_Message_First_Line
     (Obj : Git_Object)
      return String;

   function Tag_Target_Id
     (Obj : Git_Object)
      return Hex_Object_Id;

   function Flatten_Tree
     (Repo    : Version.Repository.Repository_Handle;
      Tree_Id : Hex_Object_Id)
      return Tree_Entry_Vectors.Vector;

   function Tree_Entries
     (Repo    : Version.Repository.Repository_Handle;
      Tree_Id : Hex_Object_Id)
      return Tree_Entry_Vectors.Vector;
   --  Parse a single level of Tree_Id (non-recursive): subtrees are returned
   --  as Tree_Directory entries (paths are entry names, not full paths).

   function Parse_Tree
     (Algorithm : Version.Hash.Hash_Algorithm;
      Data      : String)
      return Tree_Entry_Vectors.Vector;
   --  Parse raw tree-object bytes (the payload after the "tree <size>\0"
   --  header) into single-level entries. The object-id width is taken from
   --  Algorithm (20 raw bytes for Sha1, 32 for Sha256), so the same parser
   --  handles SHA-1 and SHA-256 trees.

   function Kind
     (Obj : Git_Object)
      return Object_Kind;

   function Content
     (Obj : Git_Object)
      return String;

private

   type Git_Object is record
      Kind_Value    : Object_Kind := Unknown_Object;
      Content_Value : Unbounded_String;
   end record;

end Version.Objects;
