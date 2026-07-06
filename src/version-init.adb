with Ada.IO_Exceptions;

with Version.Files;
with Version.Platform;

package body Version.Init is

   use type Version.Hash.Hash_Algorithm;

   LF : constant Character := Character'Val (10);
   HT : constant Character := Character'Val (9);

   procedure Ensure_Directory
     (Path : String)
   is
   begin
      Version.Files.Create_Directory_If_Missing (Path);
   end Ensure_Directory;

   --  Git writes repositoryformatversion = 1 and an [extensions] block with
   --  objectformat = sha256 for a SHA-256 repository; a SHA-1 repository keeps
   --  version 0 and no extensions.
   function Config_Content
     (Bare          : Boolean;
      Object_Format : Version.Hash.Hash_Algorithm)
      return String
   is
      Is_Sha256 : constant Boolean := Object_Format = Version.Hash.Sha256;
      Version_Line : constant String :=
        (if Is_Sha256 then "1" else "0");
      Bare_Line : constant String :=
        (if Bare then "true" else "false");
      Base : constant String :=
        "[core]" & LF
        & HT & "repositoryformatversion = " & Version_Line & LF
        & HT & "filemode = " & Version.Platform.Core_Filemode_Default & LF
        & HT & "bare = " & Bare_Line & LF
        & HT & "logallrefupdates = true" & LF;
   begin
      if Is_Sha256 then
         return
           Base
           & "[extensions]" & LF
           & HT & "objectformat = sha256" & LF;
      else
         return Base;
      end if;
   end Config_Content;

   procedure Init
     (Path          : String := ".";
      Object_Format : Version.Hash.Hash_Algorithm := Version.Hash.Sha1)
   is
      Git_Dir : constant String :=
        Version.Files.Join (Path, ".git");
   begin
      if Path'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with
           "init path must not be empty";
      end if;

      if Version.Files.Is_Directory (Git_Dir) then
         raise Ada.IO_Exceptions.Data_Error with
           "repository already exists: " & Git_Dir;
      end if;

      Ensure_Directory (Path);

      Ensure_Directory (Git_Dir);
      Ensure_Directory (Version.Files.Join (Git_Dir, "objects"));
      Ensure_Directory (Version.Files.Join (Git_Dir, "objects/pack"));
      Ensure_Directory (Version.Files.Join (Git_Dir, "refs"));
      Ensure_Directory (Version.Files.Join (Git_Dir, "refs/heads"));
      Ensure_Directory (Version.Files.Join (Git_Dir, "refs/tags"));
      Ensure_Directory (Version.Files.Join (Git_Dir, "hooks"));

      Version.Files.Write_Binary_File_Atomic
        (Path    => Version.Files.Join (Git_Dir, "HEAD"),
         Content => "ref: refs/heads/main" & LF);

      Version.Files.Write_Binary_File_Atomic
        (Path    => Version.Files.Join (Git_Dir, "config"),
         Content => Config_Content (Bare => False, Object_Format => Object_Format));
   end Init;

   procedure Init_Bare
     (Path          : String := ".";
      Object_Format : Version.Hash.Hash_Algorithm := Version.Hash.Sha1)
   is
   begin
      if Path'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with
         "bare init path must not be empty";
      end if;

      if Version.Files.Is_Directory (Version.Files.Join (Path, "objects")) then
         raise Ada.IO_Exceptions.Data_Error with
         "bare repository already exists: " & Path;
      end if;

      Ensure_Directory (Path);
      Ensure_Directory (Version.Files.Join (Path, "objects"));
      Ensure_Directory (Version.Files.Join (Path, "objects/pack"));
      Ensure_Directory (Version.Files.Join (Path, "refs"));
      Ensure_Directory (Version.Files.Join (Path, "refs/heads"));
      Ensure_Directory (Version.Files.Join (Path, "refs/tags"));
      Ensure_Directory (Version.Files.Join (Path, "hooks"));

      Version.Files.Write_Binary_File_Atomic
      (Path    => Version.Files.Join (Path, "HEAD"),
         Content => "ref: refs/heads/main" & LF);

      Version.Files.Write_Binary_File_Atomic
      (Path    => Version.Files.Join (Path, "config"),
         Content => Config_Content (Bare => True, Object_Format => Object_Format));
   end Init_Bare;

end Version.Init;
