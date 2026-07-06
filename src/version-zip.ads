with Ada.Streams.Stream_IO;
with Ada.Strings.Unbounded;
with Interfaces;
with Ada.Containers.Vectors;
with Ada.Containers.Ordered_Sets;

package Version.Zip is

   type Zip_Writer is limited private;

   procedure Create
     (Writer      : in out Zip_Writer;
      Output_Path : String);

   procedure Add_File
     (Writer       : in out Zip_Writer;
      Archive_Path : String;
      Content      : String;
      Executable   : Boolean := False);

   procedure Add_Directory
     (Writer       : in out Zip_Writer;
      Archive_Path : String);

   procedure Add_Symlink
     (Writer       : in out Zip_Writer;
      Archive_Path : String;
      Link_Target  : String);

   procedure Close
     (Writer : in out Zip_Writer);

private
   use Ada.Strings.Unbounded;
   use Interfaces;

   type Central_Entry is record
      Name        : Unbounded_String;
      CRC         : Unsigned_32 := 0;
      Compressed_Size   : Unsigned_32 := 0;
      Uncompressed_Size : Unsigned_32 := 0;
      Offset            : Unsigned_32 := 0;
      External    : Unsigned_32 := 0;
      Method      : Unsigned_16 := 0;
      Directory   : Boolean := False;
      Symlink     : Boolean := False;
   end record;

   package Central_Entry_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Central_Entry);

   package Name_Sets is new Ada.Containers.Ordered_Sets
     (Element_Type => Unbounded_String);

   type Zip_Writer is limited record
      File    : Ada.Streams.Stream_IO.File_Type;
      Open    : Boolean := False;
      Offset  : Unsigned_32 := 0;
      Entries : Central_Entry_Vectors.Vector;
      Names   : Name_Sets.Set;
   end record;

end Version.Zip;
