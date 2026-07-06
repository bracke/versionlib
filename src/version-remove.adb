with Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Strings.Unbounded;

with Version.Repository;
with Version.Staging;
with Version.Files;
with Version.Filesystem_Guard;
with Version.Path_Safety;

package body Version.Remove is

   use Ada.Strings.Unbounded;

   procedure Remove_Path
     (Path : String)
   is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;

      Normalized : constant String :=
        Version.Path_Safety.Normalize_Relative_Path (Path);

      Entries : Version.Staging.Index_Entry_Vectors.Vector :=
        Version.Staging.Load (Repo);

      Found : Boolean := False;
   begin
      Version.Path_Safety.Require_Safe_Relative_Path
        (Normalized, "remove path");

      if not Entries.Is_Empty then
         declare
            I : Natural := Entries.First_Index;
         begin
            while I <= Entries.Last_Index loop
               if To_String (Entries.Element (I).Path) = Normalized then
                  Entries.Delete (I);
                  Found := True;
                  exit;
               end if;

               I := I + 1;
            end loop;
         end;
      end if;

      if not Found then
         raise Ada.IO_Exceptions.Data_Error with
           "path is not tracked: " & Normalized;
      end if;

      declare
         Full_Path : constant String :=
           Version.Files.Join (Version.Repository.Root_Path (Repo), Normalized);
      begin
         if Ada.Directories.Exists (Version.Files.To_Native_Path (Full_Path)) then
            if Version.Files.Is_Ordinary_File (Full_Path) then
               Version.Filesystem_Guard.Require_Safe_Delete_Target
                 (Repo_Root     => Version.Repository.Root_Path (Repo),
                  Relative_Path => Normalized);
            else
               raise Ada.IO_Exceptions.Data_Error with
                 "path is not a regular file: " & Normalized;
            end if;
         end if;
      end;

      Version.Staging.Write
        (Repo    => Repo,
         Entries => Entries);

      Version.Files.Remove_File_If_Safe
        (Repo_Root     => Version.Repository.Root_Path (Repo),
         Relative_Path => Normalized);
   end Remove_Path;

end Version.Remove;