with Version.Pathspec;
with Version.Repository;

package Version.Archive is

   function Unsupported_Output_Format_Text (Output : String) return String;

   type Archive_Format is
     (Tar_Format,
      Zip_Format);

   procedure Create
     (Repository : Version.Repository.Repository_Handle;
      Revision   : String;
      Output     : String;
      Format     : Archive_Format := Tar_Format);

   procedure Create
     (Repository : Version.Repository.Repository_Handle;
      Revision   : String;
      Output     : String;
      Format     : Archive_Format;
      Pathspecs  : Version.Pathspec.Pathspec_Vectors.Vector);

   procedure Create
     (Repository : Version.Repository.Repository_Handle;
      Revision   : String;
      Output     : String;
      Format     : Archive_Format;
      Pathspecs  : Version.Pathspec.Pathspec_Vectors.Vector;
      Prefix     : String);

end Version.Archive;
