with Ada.Streams.Stream_IO;
with Ada.Strings.Unbounded;
with Ada.Containers.Vectors;

package Version.Tar is

   use Ada.Strings.Unbounded;

   type Tar_Writer is limited private;

   procedure Create
     (Writer      : in out Tar_Writer;
      Output_Path : String);

   procedure Add_File
     (Writer       : in out Tar_Writer;
      Archive_Path : String;
      Content      : String;
      Executable   : Boolean := False);

   procedure Add_Directory
     (Writer       : in out Tar_Writer;
      Archive_Path : String);

   procedure Add_Symlink
     (Writer       : in out Tar_Writer;
      Archive_Path : String;
      Link_Target  : String);

   procedure Close
     (Writer : in out Tar_Writer);

private

   package Name_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Unbounded_String);

   type Tar_Writer is limited record
      File  : Ada.Streams.Stream_IO.File_Type;
      Open  : Boolean := False;
      Names : Name_Vectors.Vector;
   end record;

end Version.Tar;
