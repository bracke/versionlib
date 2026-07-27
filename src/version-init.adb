with Ada.IO_Exceptions;

with Version.Files;
with Version.Platform;
with Version.Reftable.Writer;

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

   --  Git writes repositoryformatversion = 1 with an [extensions] block when
   --  objectformat = sha256 and/or refstorage = reftable is in effect; a plain
   --  SHA-1 files repository keeps version 0 and no extensions.
   function Config_Content
     (Bare          : Boolean;
      Object_Format : Version.Hash.Hash_Algorithm;
      Ref_Storage   : Ref_Storage_Kind)
      return String
   is
      Is_Sha256   : constant Boolean := Object_Format = Version.Hash.Sha256;
      Is_Reftable : constant Boolean := Ref_Storage = Reftable;
      Needs_V1    : constant Boolean := Is_Sha256 or else Is_Reftable;
      Version_Line : constant String := (if Needs_V1 then "1" else "0");
      Bare_Line   : constant String := (if Bare then "true" else "false");
      --  git omits core.logallrefupdates in a bare repository (the reflog
      --  default is off there); a non-bare repo gets it set to true.
      Base : constant String :=
        "[core]" & LF
        & HT & "repositoryformatversion = " & Version_Line & LF
        & HT & "filemode = " & Version.Platform.Core_Filemode_Default & LF
        & HT & "bare = " & Bare_Line & LF
        & (if Bare then "" else HT & "logallrefupdates = true" & LF);
      Extensions : constant String :=
        (if Is_Sha256 then HT & "objectformat = sha256" & LF else "")
        & (if Is_Reftable then HT & "refstorage = reftable" & LF else "");
   begin
      if Extensions'Length > 0 then
         return Base & "[extensions]" & LF & Extensions;
      else
         return Base;
      end if;
   end Config_Content;

   --  HEAD content for a new repository: reftable keeps a `.invalid` stub on
   --  disk (the real HEAD symref lives in the table), files points at the
   --  default branch directly.
   function Head_Content
     (Ref_Storage : Ref_Storage_Kind; Branch : String) return String is
     (if Ref_Storage = Reftable
      then "ref: refs/heads/.invalid" & LF
      else "ref: refs/heads/" & Branch & LF);

   procedure Setup_Reftable
     (Git_Dir       : String;
      Object_Format : Version.Hash.Hash_Algorithm;
      Branch        : String) is
   begin
      Version.Reftable.Writer.Initialize_Stack
        (Common_Git_Dir => Git_Dir,
         Default_Branch  => Branch,
         Raw_Length      => Version.Hash.Raw_Length (Object_Format));
   end Setup_Reftable;

   --  git seeds a fresh repository with a description placeholder and an
   --  info/exclude template; create them (but never clobber existing ones).
   procedure Write_Description_And_Info (Git_Dir : String) is
   begin
      Ensure_Directory (Version.Files.Join (Git_Dir, "info"));
      if not Version.Files.Is_Ordinary_File
               (Version.Files.Join (Git_Dir, "description"))
      then
         Version.Files.Write_Binary_File_Atomic
           (Path    => Version.Files.Join (Git_Dir, "description"),
            Content =>
              "Unnamed repository; edit this file 'description' to name the "
              & "repository." & LF);
      end if;
      if not Version.Files.Is_Ordinary_File
               (Version.Files.Join (Git_Dir, "info/exclude"))
      then
         Version.Files.Write_Binary_File_Atomic
           (Path    => Version.Files.Join (Git_Dir, "info/exclude"),
            Content =>
              "# git ls-files --others --exclude-from=.git/info/exclude" & LF
              & "# Lines that start with '#' are comments." & LF
              & "# For a project mostly in C, the following would be a good "
              & "set of" & LF
              & "# exclude patterns (uncomment them if you want to use them):"
              & LF & "# *.[oa]" & LF & "# *~" & LF);
      end if;
   end Write_Description_And_Info;

   procedure Init
     (Path           : String := ".";
      Object_Format  : Version.Hash.Hash_Algorithm := Version.Hash.Sha1;
      Ref_Storage    : Ref_Storage_Kind := Files;
      Initial_Branch : String := "main")
   is
      Git_Dir : constant String :=
        Version.Files.Join (Path, ".git");
      --  git's `init` is idempotent: re-running it reinitialises an existing
      --  repository (ensuring the directory structure) without overwriting an
      --  existing HEAD or config.
      Existed : constant Boolean := Version.Files.Is_Directory (Git_Dir);
   begin
      if Path'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with
           "init path must not be empty";
      end if;

      Ensure_Directory (Path);

      Ensure_Directory (Git_Dir);
      Ensure_Directory (Version.Files.Join (Git_Dir, "objects"));
      Ensure_Directory (Version.Files.Join (Git_Dir, "objects/pack"));
      Ensure_Directory (Version.Files.Join (Git_Dir, "refs"));
      Ensure_Directory (Version.Files.Join (Git_Dir, "refs/heads"));
      Ensure_Directory (Version.Files.Join (Git_Dir, "refs/tags"));
      Ensure_Directory (Version.Files.Join (Git_Dir, "hooks"));
      Write_Description_And_Info (Git_Dir);

      if not Version.Files.Is_Ordinary_File
               (Version.Files.Join (Git_Dir, "HEAD"))
      then
         Version.Files.Write_Binary_File_Atomic
           (Path    => Version.Files.Join (Git_Dir, "HEAD"),
            Content => Head_Content (Ref_Storage, Initial_Branch));
      end if;

      if not Version.Files.Is_Ordinary_File
               (Version.Files.Join (Git_Dir, "config"))
      then
         Version.Files.Write_Binary_File_Atomic
           (Path    => Version.Files.Join (Git_Dir, "config"),
            Content =>
              Config_Content (False, Object_Format, Ref_Storage));
      end if;

      if Ref_Storage = Reftable and then not Existed then
         Setup_Reftable (Git_Dir, Object_Format, Initial_Branch);
      end if;
   end Init;

   procedure Init_Bare
     (Path           : String := ".";
      Object_Format  : Version.Hash.Hash_Algorithm := Version.Hash.Sha1;
      Ref_Storage    : Ref_Storage_Kind := Files;
      Initial_Branch : String := "main")
   is
      --  git's bare `init` is idempotent too: it reinitialises rather than
      --  failing, and preserves an existing HEAD/config.
      Existed : constant Boolean :=
        Version.Files.Is_Directory (Version.Files.Join (Path, "objects"));
   begin
      if Path'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with
         "bare init path must not be empty";
      end if;

      Ensure_Directory (Path);
      Ensure_Directory (Version.Files.Join (Path, "objects"));
      Ensure_Directory (Version.Files.Join (Path, "objects/pack"));
      Ensure_Directory (Version.Files.Join (Path, "refs"));
      Ensure_Directory (Version.Files.Join (Path, "refs/heads"));
      Ensure_Directory (Version.Files.Join (Path, "refs/tags"));
      Ensure_Directory (Version.Files.Join (Path, "hooks"));
      Write_Description_And_Info (Path);

      if not Version.Files.Is_Ordinary_File
               (Version.Files.Join (Path, "HEAD"))
      then
         Version.Files.Write_Binary_File_Atomic
           (Path    => Version.Files.Join (Path, "HEAD"),
            Content => Head_Content (Ref_Storage, Initial_Branch));
      end if;

      if not Version.Files.Is_Ordinary_File
               (Version.Files.Join (Path, "config"))
      then
         Version.Files.Write_Binary_File_Atomic
           (Path    => Version.Files.Join (Path, "config"),
            Content => Config_Content (True, Object_Format, Ref_Storage));
      end if;

      if Ref_Storage = Reftable and then not Existed then
         Setup_Reftable (Path, Object_Format, Initial_Branch);
      end if;
   end Init_Bare;

end Version.Init;
