with Ada.Directories; use Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Strings.Unbounded;
with Interfaces.C;
with System;

with GNAT.OS_Lib;

with Version.Files;
with Version.LFS;
with Version.Text_Filter;
with Version.Availability;
with Version.Objects;
with Version.Path_Safety;
with Version.Platform;
with Version.Repository;
with Version.Sparse;
with Version.Staging;
with Version.Submodules;
with Version.Write;

package body Version.Stage is

   function Readlink
     (Path   : System.Address;
      Buf    : System.Address;
      Bufsiz : Interfaces.C.size_t) return Integer;
   pragma Import (C, Readlink, "__gnat_readlink");

   function Symlink_Target (Path : String) return String is
      Native_Path : constant String := Version.Files.To_Native_Path (Path);
      C_Path      : aliased String := Native_Path & Character'Val (0);
      Buffer      : aliased String (1 .. 8192);
      Count       : constant Integer :=
        Readlink
          (Path   => C_Path (C_Path'First)'Address,
           Buf    => Buffer (Buffer'First)'Address,
           Bufsiz => Interfaces.C.size_t (Buffer'Length));
   begin
      if Count < 0 then
         raise Ada.IO_Exceptions.Data_Error with
           "could not read symbolic link target: " & Path;
      elsif Count = 0 then
         raise Ada.IO_Exceptions.Data_Error with
           "empty symbolic link target: " & Path;
      elsif Count >= Buffer'Length then
         raise Ada.IO_Exceptions.Data_Error with
           "symbolic link target too long: " & Path;
      end if;

      return Buffer (Buffer'First .. Buffer'First + Count - 1);
   end Symlink_Target;

   function File_Index_Mode (Path : String) return String is
   begin
      if Version.Platform.Supports_Executable_Bit
        and then GNAT.OS_Lib.Is_Executable_File
                   (Version.Files.To_Native_Path (Path))
      then
         return "100755";
      else
         return "100644";
      end if;
   end File_Index_Mode;

   procedure Stage_Path (Path : String) is
      use Ada.Strings.Unbounded;

      Safe_Path : constant String :=
        Version.Path_Safety.Normalize_Relative_Path (Path);

      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;

      Full_Path : constant String :=
        Version.Files.Join (Version.Repository.Root_Path (Repo), Safe_Path);

      Entries : Version.Staging.Index_Entry_Vectors.Vector :=
        Version.Staging.Load (Repo);

      Blob_Id : Version.Objects.Object_Id_Storage;
   begin
      Version.Path_Safety.Require_Safe_Relative_Path (Safe_Path);

      if GNAT.OS_Lib.Is_Symbolic_Link
           (Version.Files.To_Native_Path (Full_Path))
      then
         Blob_Id := Version.Write.Write_Blob
           (Repo    => Repo,
            Content => Symlink_Target (Full_Path));

         Version.Staging.Replace_Entry
           (Entries,
            (Path  => To_Unbounded_String (Safe_Path),
             Id    => Blob_Id,
             Mode  => To_Unbounded_String ("120000"),
             Stage => 0, Skip_Worktree => False));

      else
         if not Ada.Directories.Exists (Full_Path) then
            if Version.Sparse.Enabled (Repo)
              and then not Version.Sparse.Included (Repo, Safe_Path)
            then
               raise Ada.IO_Exceptions.Data_Error with
                 Version.Availability.Path_Excluded_By_Sparse_Checkout (Safe_Path);
            end if;

            raise Ada.IO_Exceptions.Data_Error with
              "path does not exist: " & Safe_Path;
         elsif Ada.Directories.Kind (Full_Path) /= Ada.Directories.Ordinary_File then
            if Version.Submodules.Is_Submodule_Path (Repo, Safe_Path) then
               Version.Submodules.Stage_Submodule (Repo, Safe_Path);
               return;
            end if;

            raise Ada.IO_Exceptions.Data_Error with
              "path is not a regular file: " & Safe_Path;
         end if;

         Blob_Id := Version.Write.Write_Blob
           (Repo    => Repo,
            Content => Version.Text_Filter.Clean_Content
              (Repo          => Repo,
               Relative_Path => Safe_Path,
               Content       => Version.LFS.Clean_Content
                 (Repo          => Repo,
                  Relative_Path => Safe_Path,
                  Content       =>
                    Version.Files.Read_Binary_File (Full_Path))));

         Version.Staging.Replace_Entry
           (Entries,
            (Path  => To_Unbounded_String (Safe_Path),
             Id    => Blob_Id,
             Mode  => To_Unbounded_String (File_Index_Mode (Full_Path)),
             Stage => 0, Skip_Worktree => False));
      end if;

      Version.Staging.Sort_By_Path (Entries);
      Version.Staging.Write (Repo => Repo, Entries => Entries);
   end Stage_Path;

end Version.Stage;
