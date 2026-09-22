with Ada.Environment_Variables;
with Ada.IO_Exceptions;

with GNAT.OS_Lib;

with Version.Config;
with Version.Files;

package body Version.Editor is

   use type GNAT.OS_Lib.String_Access;

   function Env (Name : String) return String is
     (if Ada.Environment_Variables.Exists (Name)
      then Ada.Environment_Variables.Value (Name) else "");

   --  git's is_terminal_dumb: no TERM at all counts as dumb.
   function Terminal_Is_Dumb return Boolean is
     (Env ("TERM") = "" or else Env ("TERM") = "dumb");

   function Configured
     (Repo     : Version.Repository.Repository_Handle;
      Fallback : Boolean := True) return String
   is
      Core : constant String :=
        (if Version.Config.Has_Key (Repo, "core.editor")
         then Version.Config.Trim (Version.Config.Get_Value (Repo, "core.editor"))
         else "");
      Dumb : constant Boolean := Terminal_Is_Dumb;
   begin
      if Env ("GIT_EDITOR") /= "" then
         return Env ("GIT_EDITOR");
      elsif Core /= "" then
         return Core;
      elsif not Dumb and then Env ("VISUAL") /= "" then
         --  git skips VISUAL on a dumb terminal, but still honours EDITOR.
         return Env ("VISUAL");
      elsif Env ("EDITOR") /= "" then
         return Env ("EDITOR");
      elsif Dumb then
         --  git's git_editor returns nothing rather than falling back to vi,
         --  and the caller reports "Terminal is dumb, but EDITOR unset".
         return "";
      elsif Fallback then
         return "vi";
      else
         return "";
      end if;
   end Configured;

   function Edit_File
     (Repo    : Version.Repository.Repository_Handle;
      Path    : String;
      Content : String) return String
   is
      Editor : constant String := Configured (Repo);
      Args   : GNAT.OS_Lib.Argument_List (1 .. 4) := [others => null];
      Status : Integer;
   begin
      if Editor'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with
           "Terminal is dumb, but EDITOR unset";
      end if;

      Version.Files.Write_Binary_File_Atomic (Path => Path, Content => Content);

      --  git's launch_editor: sh -c '<editor> "$@"' <editor> <path>, so
      --  the editor string may carry its own arguments and "$1" is the
      --  file.
      Args (1) := new String'("-c");
      Args (2) := new String'(Editor & " ""$@""");
      Args (3) := new String'(Editor);
      Args (4) := new String'(Path);
      Status := GNAT.OS_Lib.Spawn ("/bin/sh", Args);
      for I in Args'Range loop
         GNAT.OS_Lib.Free (Args (I));
      end loop;

      if Status /= 0 then
         raise Ada.IO_Exceptions.Data_Error with
           "There was a problem with the editor '" & Editor & "'.";
      end if;

      return Version.Files.Read_Binary_File (Path);
   exception
      when others =>
         for I in Args'Range loop
            if Args (I) /= null then
               GNAT.OS_Lib.Free (Args (I));
            end if;
         end loop;
         raise;
   end Edit_File;

end Version.Editor;
