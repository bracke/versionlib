with Ada.Characters.Handling;
with Ada.Directories;
with Ada.Strings.Fixed;
with GNAT.OS_Lib;

with Version.Config;
with Version.Files;

package body Version.Credential is

   LF : constant Character := Character'Val (10);

   function Serialize (Cred : Credential) return String is
      R : Unbounded_String;
      procedure Add (Key : String; Value : Unbounded_String) is
      begin
         if Length (Value) > 0 then
            Append (R, Key & "=" & To_String (Value) & LF);
         end if;
      end Add;
   begin
      Add ("protocol", Cred.Protocol);
      Add ("host", Cred.Host);
      Add ("path", Cred.Path);
      Add ("username", Cred.Username);
      Add ("password", Cred.Password);
      return To_String (R);
   end Serialize;

   procedure Parse (Text : String; Cred : in out Credential) is
      Pos : Natural := Text'First;
   begin
      while Pos <= Text'Last loop
         declare
            Stop : Natural := Pos;
         begin
            while Stop <= Text'Last and then Text (Stop) /= LF loop
               Stop := Stop + 1;
            end loop;
            declare
               Line : constant String := Text (Pos .. Stop - 1);
               Eq   : constant Natural := Ada.Strings.Fixed.Index (Line, "=");
            begin
               if Eq /= 0 then
                  declare
                     Key : constant String := Line (Line'First .. Eq - 1);
                     Val : constant String := Line (Eq + 1 .. Line'Last);
                  begin
                     if Key = "protocol" then
                        Cred.Protocol := To_Unbounded_String (Val);
                     elsif Key = "host" then
                        Cred.Host := To_Unbounded_String (Val);
                     elsif Key = "path" then
                        Cred.Path := To_Unbounded_String (Val);
                     elsif Key = "username" then
                        Cred.Username := To_Unbounded_String (Val);
                     elsif Key = "password" then
                        Cred.Password := To_Unbounded_String (Val);
                     end if;
                  end;
               end if;
            end;
            Pos := Stop + 1;
         end;
      end loop;
   end Parse;

   --  Collect the configured credential.helper values, in order.
   function Helpers (Repo : Version.Repository.Repository_Handle)
     return Version.Config.Config_Entry_Vectors.Vector
   is
      All_Entries : constant Version.Config.Config_Entry_Vectors.Vector :=
        Version.Config.Read_All (Repo);
      Result : Version.Config.Config_Entry_Vectors.Vector;
      function Lower (S : String) return String
        renames Ada.Characters.Handling.To_Lower;
   begin
      for E of All_Entries loop
         if Lower (Version.Config.Config_Entry_Name (E)) = "credential.helper"
         then
            Result.Append (E);
         end if;
      end loop;
      return Result;
   end Helpers;

   --  Translate a credential.helper config value into an executable command,
   --  following git's rules: a leading '!' is a shell command; a value with a
   --  slash is a path; a bare name maps to git-credential-<name>.
   function Helper_Command (Value : String) return String is
   begin
      if Value'Length > 0 and then Value (Value'First) = '!' then
         return Value (Value'First + 1 .. Value'Last);
      elsif (for some C of Value => C = '/') then
         return Value;
      else
         return "git-credential-" & Value;
      end if;
   end Helper_Command;

   --  Run one helper with Action, feeding Input on stdin; returns its stdout.
   function Run_Helper
     (Repo    : Version.Repository.Repository_Handle;
      Command : String;
      Action  : String;
      Input   : String)
      return String
   is
      use Version.Files;
      Git_Dir : constant String := Version.Repository.Git_Dir (Repo);
      In_Path  : constant String := Join (Git_Dir, "VERSION_CRED_IN");
      Out_Path : constant String := Join (Git_Dir, "VERSION_CRED_OUT");
      Status : Integer;
      Args : GNAT.OS_Lib.Argument_List (1 .. 2);
   begin
      Delete_File_If_Exists (In_Path);
      Delete_File_If_Exists (Out_Path);
      --  Helpers read a record terminated by a blank line.
      Write_Binary_File_Atomic (In_Path, Input & LF);

      --  Run via the shell so both "!cmd" and program helpers work, with the
      --  protocol on stdin and the reply captured from stdout.
      Args := [1 => new String'("-c"),
               2 => new String'
                      (Command & " " & Action
                       & " < '" & In_Path & "' > '" & Out_Path & "'")];
      Status := GNAT.OS_Lib.Spawn ("/bin/sh", Args);
      GNAT.OS_Lib.Free (Args (1));
      GNAT.OS_Lib.Free (Args (2));

      declare
         Output : constant String :=
           (if Ada.Directories.Exists (Out_Path)
            then Read_Binary_File (Out_Path) else "");
      begin
         Delete_File_If_Exists (In_Path);
         Delete_File_If_Exists (Out_Path);
         if Status /= 0 then
            return "";
         end if;
         return Output;
      end;
   end Run_Helper;

   procedure Fill
     (Repo : Version.Repository.Repository_Handle;
      Cred : in out Credential) is
   begin
      for E of Helpers (Repo) loop
         exit when Length (Cred.Username) > 0 and then Length (Cred.Password) > 0;
         declare
            Cmd : constant String :=
              Helper_Command (To_String (E.Value));
            Reply : constant String :=
              Run_Helper (Repo, Cmd, "get", Serialize (Cred));
         begin
            Parse (Reply, Cred);
         end;
      end loop;
   end Fill;

   procedure Store_Or_Erase
     (Repo : Version.Repository.Repository_Handle;
      Cred : Credential;
      Action : String)
   is
   begin
      for E of Helpers (Repo) loop
         declare
            Cmd : constant String :=
              Helper_Command (To_String (E.Value));
            Discard : constant String :=
              Run_Helper (Repo, Cmd, Action, Serialize (Cred));
            pragma Unreferenced (Discard);
         begin
            null;
         end;
      end loop;
   end Store_Or_Erase;

   procedure Approve
     (Repo : Version.Repository.Repository_Handle;
      Cred : Credential) is
   begin
      Store_Or_Erase (Repo, Cred, "store");
   end Approve;

   procedure Reject
     (Repo : Version.Repository.Repository_Handle;
      Cred : Credential) is
   begin
      Store_Or_Erase (Repo, Cred, "erase");
   end Reject;

end Version.Credential;
