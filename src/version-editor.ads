with Version.Repository;

package Version.Editor is

   --  The program git opens a message in: GIT_EDITOR, else core.editor,
   --  else VISUAL, else EDITOR, else "vi". Empty when Fallback is False and
   --  nothing is configured.
   function Configured
     (Repo     : Version.Repository.Repository_Handle;
      Fallback : Boolean := True) return String;

   --  Write Content to Path, open Path in the configured editor, and return
   --  the file's content afterwards. The editor string is run through the
   --  shell with the path appended, exactly as git's launch_editor does, so
   --  "code --wait" and quoted paths behave. Raises Data_Error when no editor
   --  can be found or it exits non-zero (git: "There was a problem with the
   --  editor '<ed>'."). The file is left in place for the caller to clean up.
   function Edit_File
     (Repo    : Version.Repository.Repository_Handle;
      Path    : String;
      Content : String) return String;

end Version.Editor;
