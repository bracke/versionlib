with Ada.Streams.Stream_IO;
with Ada.Strings.Unbounded;
with Ada.Containers.Vectors;

package Version.Tar is

   use Ada.Strings.Unbounded;

   type Tar_Writer is limited private;

   procedure Create
     (Writer      : in out Tar_Writer;
      Output_Path : String;
      Mtime       : Natural := 0);
   --  Mtime is the modification time stamped into every entry's header
   --  (git archive uses the archived commit's committer time; 0 otherwise).

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

   --  Emit a POSIX pax global extended header (`git archive` writes one first,
   --  carrying `comment=<commit-id>`, which `git get-tar-commit-id` reads).
   --  Comment is the value of the "comment" record.
   procedure Add_Pax_Global_Header
     (Writer  : in out Tar_Writer;
      Comment : String);

   procedure Close
     (Writer : in out Tar_Writer);

private

   package Name_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Unbounded_String);

   type Tar_Writer is limited record
      File  : Ada.Streams.Stream_IO.File_Type;
      Open  : Boolean := False;
      Mtime : Natural := 0;
      Names : Name_Vectors.Vector;
   end record;

end Version.Tar;
