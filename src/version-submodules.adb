with Ada.Directories; use Ada.Directories;
with Ada.Environment_Variables;
with Ada.IO_Exceptions; use Ada.IO_Exceptions;

with Ada.Strings.Fixed;
with Ada.Text_IO;

with GNAT.OS_Lib;

with Version.Clone;
with Version.Config;
with Version.Fetch;
with Version.Files;
with Version.Filesystem_Guard; use Version.Filesystem_Guard;
with Version.Gitmodules;

with Version.Packed_Refs;
with Version.Path_Safety;
with Version.Platform;
with Version.Refs;
with Version.Remotes;
with Version.Restore;
with Version.Sparse;
with Version.Staging;
with Version.Status;
with Version.Transport; use Version.Transport;

package body Version.Submodules is
   use Version.Objects;

   function Join (Left, Right : String) return String
   renames Version.Files.Join;

   function Read_Gitdir_File (Git_File : String) return String;

   function Is_Windows_Drive_Path (Text : String) return Boolean;

   function Resolved_Submodule_Git_Dir
     (Repo : Version.Repository.Repository_Handle; Path : String)
      return String;

   procedure Validate_Committed_Gitmodules
     (Repo : Version.Repository.Repository_Handle);

   function Canonical_Submodule_Path (Path : String) return String is
   begin
      return Version.Path_Safety.Normalize_Relative_Path (Path);
   exception
      when Ada.IO_Exceptions.Data_Error =>
         raise Ada.IO_Exceptions.Data_Error
           with "unsafe submodule path: " & Path;
   end Canonical_Submodule_Path;

   function Admin_Name (Path : String) return String is
   begin
      return Canonical_Submodule_Path (Path);
   end Admin_Name;

   function Submodule_Worktree_Path
     (Repo : Version.Repository.Repository_Handle; Path : String) return String
   is
      Safe_Path : constant String := Canonical_Submodule_Path (Path);
   begin
      return Join (Version.Repository.Root_Path (Repo), Safe_Path);
   end Submodule_Worktree_Path;

   function Submodule_Admin_Root
     (Repo : Version.Repository.Repository_Handle) return String
   is
   begin
      return Join (Version.Repository.Git_Dir (Repo), "modules");
   end Submodule_Admin_Root;

   function Submodule_Admin_Path
     (Repo : Version.Repository.Repository_Handle; Path : String) return String
   is
   begin
      return Join (Submodule_Admin_Root (Repo), Admin_Name (Path));
   end Submodule_Admin_Path;

   function Lexically_Normalized_Path (Path : String) return String is
      P      : constant String := Version.Files.Normalize_Separators (Path);
      Result : Unbounded_String;
      First  : Natural := P'First;

      procedure Pop_Last_Segment is
         Current : constant String := To_String (Result);
         Slash   : Natural := 0;
      begin
         if Current = "/" or else Current'Length = 0 then
            return;
         end if;

         for I in reverse Current'Range loop
            if Current (I) = '/' then
               Slash := I;
               exit;
            end if;
         end loop;

         if Slash = 0 then
            Result := Null_Unbounded_String;
         elsif Slash = Current'First then
            Result := To_Unbounded_String ("/");
         else
            Result :=
              To_Unbounded_String (Current (Current'First .. Slash - 1));
         end if;
      end Pop_Last_Segment;

      procedure Append_Segment (Segment : String) is
         Current : constant String := To_String (Result);
      begin
         if Segment'Length = 0 or else Segment = "." then
            return;
         elsif Segment = ".." then
            Pop_Last_Segment;
            return;
         end if;

         if Current'Length > 0 and then Current (Current'Last) /= '/' then
            Append (Result, "/");
         end if;

         Append (Result, Segment);
      end Append_Segment;

   begin
      if P'Length = 0 then
         return "";
      end if;

      if P (P'First) = '/' then
         Result := To_Unbounded_String ("/");
         First := P'First + 1;
      end if;

      while First <= P'Last loop
         while First <= P'Last and then P (First) = '/' loop
            First := First + 1;
         end loop;

         exit when First > P'Last;

         declare
            Last : Natural := First;
         begin
            while Last <= P'Last and then P (Last) /= '/' loop
               Last := Last + 1;
            end loop;

            Append_Segment (P (First .. Last - 1));
            First := Last + 1;
         end;
      end loop;

      if Length (Result) = 0 and then P (P'First) = '/' then
         return "/";
      end if;

      return To_String (Result);
   end Lexically_Normalized_Path;

   procedure Validate_Committed_Gitmodules
     (Repo : Version.Repository.Repository_Handle)
   is
      Head_Id : constant String := Version.Refs.Current_Commit_Id (Repo);
   begin
      if Head_Id'Length = 0 then
         return;
      end if;

      declare
         Commit : constant Version.Objects.Git_Object :=
           Version.Objects.Read_Object
             (Repo, Version.Objects.To_Object_Id (Head_Id));
         Tree_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.Commit_Tree_Id (Commit);
         Entries : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Version.Objects.Flatten_Tree (Repo, Tree_Id);
      begin
         if not Entries.Is_Empty then
            for I in Entries.First_Index .. Entries.Last_Index loop
               declare
                  Tree_Item : constant Version.Objects.Tree_Entry := Entries.Element (I);
               begin
                  if To_String (Tree_Item.Path) = ".gitmodules" then
                     if Tree_Item.Kind /= Version.Objects.Tree_Blob then
                        raise Ada.IO_Exceptions.Data_Error
                          with "corrupt .gitmodules tree entry";
                     end if;

                     declare
                        Blob : constant Version.Objects.Git_Object :=
                          Version.Objects.Read_Object (Repo, Tree_Item.Id);
                     begin
                        if Version.Objects.Kind (Blob) /= Version.Objects.Blob_Object then
                           raise Ada.IO_Exceptions.Data_Error
                             with "corrupt .gitmodules blob";
                        end if;
                     end;
                  end if;
               end;
            end loop;
         end if;
      end;
   end Validate_Committed_Gitmodules;

   function Same_Or_Under (Parent, Child : String) return Boolean is
      P : constant String := Lexically_Normalized_Path (Parent);
      C : constant String := Lexically_Normalized_Path (Child);
   begin
      return
        C = P
        or else
          (C'Length > P'Length
           and then C (C'First .. C'First + P'Length - 1) = P
           and then C (C'First + P'Length) = '/');
   end Same_Or_Under;

   function Absolute_Gitdir (Work_Path : String; Gitdir : String) return String
   is
      Base : constant String :=
        Lexically_Normalized_Path
          (Ada.Directories.Full_Name
             (Version.Files.To_Native_Path (Work_Path)));
   begin
      if Gitdir'Length > 0
        and then
          (Gitdir (Gitdir'First) = '/' or else Is_Windows_Drive_Path (Gitdir))
      then
         return Lexically_Normalized_Path (Gitdir);
      end if;

      return Lexically_Normalized_Path (Join (Base, Gitdir));
   end Absolute_Gitdir;

   procedure Normalize_Submodule_Gitdir_File
     (Repo : Version.Repository.Repository_Handle; Path : String)
   is
      Work_Path : constant String := Submodule_Worktree_Path (Repo, Path);
      Dot_Git   : constant String := Join (Work_Path, ".git");
      Modules   : constant String := Submodule_Admin_Root (Repo);
   begin
      if not Ada.Directories.Exists (Version.Files.To_Native_Path (Dot_Git))
        or else
          Ada.Directories.Kind (Version.Files.To_Native_Path (Dot_Git))
          /= Ada.Directories.Ordinary_File
      then
         return;
      end if;

      declare
         Raw      : constant String := Read_Gitdir_File (Dot_Git);
         Resolved : constant String := Absolute_Gitdir (Work_Path, Raw);
      begin
         if not Same_Or_Under (Modules, Resolved) then
            raise Ada.IO_Exceptions.Data_Error
              with "submodule gitdir escapes modules directory: " & Path;
         end if;

         if not Ada.Directories.Exists
                  (Version.Files.To_Native_Path (Resolved))
           or else
             Ada.Directories.Kind (Version.Files.To_Native_Path (Resolved))
             /= Ada.Directories.Directory
         then
            raise Ada.IO_Exceptions.Data_Error
              with "submodule gitdir target does not exist: " & Path;
         end if;

         if Raw /= Resolved then
            Version.Files.Write_Binary_File_Atomic
              (Path    => Dot_Git,
               Content => "gitdir: " & Resolved & Character'Val (10));
         end if;
      end;
   end Normalize_Submodule_Gitdir_File;

   function Gitlink_Commit
     (Repo : Version.Repository.Repository_Handle; Path : String)
      return Version.Objects.Hex_Object_Id
   is
      Safe_Path : constant String := Canonical_Submodule_Path (Path);
      Index     : constant Version.Staging.Index_Entry_Vectors.Vector :=
        Version.Staging.Load (Repo);
      Pos       : constant Natural :=
        Version.Staging.Find_Path (Index, Safe_Path);
   begin
      if Pos = Natural'Last then
         raise Ada.IO_Exceptions.Data_Error
           with "submodule path is not tracked as gitlink: " & Safe_Path;
      end if;

      if To_String (Index.Element (Pos).Mode) /= "160000" then
         raise Ada.IO_Exceptions.Data_Error
           with "submodule path is not tracked as gitlink: " & Safe_Path;
      end if;

      return Index.Element (Pos).Id;
   end Gitlink_Commit;

   function Is_Submodule_Path
     (Repo : Version.Repository.Repository_Handle; Path : String)
      return Boolean
   is
      Safe_Path : constant String := Canonical_Submodule_Path (Path);
      Index     : constant Version.Staging.Index_Entry_Vectors.Vector :=
        Version.Staging.Load (Repo);
      Pos       : constant Natural :=
        Version.Staging.Find_Path (Index, Safe_Path);
   begin
      return
        Pos /= Natural'Last
        and then To_String (Index.Element (Pos).Mode) = "160000";
   end Is_Submodule_Path;

   function First_Line (Text : String) return String is
      Last : Natural := Text'First;
   begin
      while Last <= Text'Last
        and then Text (Last) /= Character'Val (10)
        and then Text (Last) /= Character'Val (13)
      loop
         Last := Last + 1;
      end loop;

      if Last = Text'First then
         return "";
      end if;

      return Text (Text'First .. Last - 1);
   end First_Line;

   function Trim_Horizontal (Text : String) return String is
      First : Natural := Text'First;
      Last  : Natural := Text'Last;
   begin
      while First <= Last
        and then (Text (First) = ' ' or else Text (First) = Character'Val (9))
      loop
         First := First + 1;
      end loop;

      while Last >= First
        and then (Text (Last) = ' ' or else Text (Last) = Character'Val (9))
      loop
         Last := Last - 1;
      end loop;

      if First > Last then
         return "";
      end if;

      return Text (First .. Last);
   end Trim_Horizontal;

   function Starts_With (Text, Prefix : String) return Boolean is
   begin
      return
        Text'Length >= Prefix'Length
        and then Text (Text'First .. Text'First + Prefix'Length - 1) = Prefix;
   end Starts_With;

   function Is_Windows_Drive_Path (Text : String) return Boolean is
   begin
      return Version.Platform.Is_Windows_Drive_Path (Text);
   end Is_Windows_Drive_Path;

   function Is_Windows_Drive_Like_Path (Text : String) return Boolean is
   begin
      return Version.Platform.Is_Windows_Drive_Like_Path (Text);
   end Is_Windows_Drive_Like_Path;

   function Has_Scheme (Text : String) return Boolean is
   begin
      for I in Text'Range loop
         if Text (I) = ':' then
            return
              I < Text'Last - 1
              and then Text (I + 1) = '/'
              and then Text (I + 2) = '/';
         end if;
      end loop;

      return False;
   end Has_Scheme;

   function Has_Scp_Like_Separator (Text : String) return Boolean is
      Colon : Natural := 0;
      Slash : Natural := 0;
   begin
      for I in Text'Range loop
         if Text (I) = ':' and then Colon = 0 then
            Colon := I;
         elsif (Text (I) = '/' or else Text (I) = '\') and then Slash = 0 then
            Slash := I;
         end if;
      end loop;

      return
        Colon /= 0
        and then Colon /= Text'First
        and then Colon /= Text'Last
        and then not Is_Windows_Drive_Like_Path (Text)
        and then (Slash = 0 or else Slash > Colon);
   end Has_Scp_Like_Separator;

   function Contains_Control (Text : String) return Boolean is
   begin
      for C of Text loop
         if C = Character'Val (0)
           or else Character'Pos (C) < 32
           or else Character'Pos (C) = 127
         then
            return True;
         end if;
      end loop;

      return False;
   end Contains_Control;

   function Is_Relative_Submodule_Url (Url : String) return Boolean is
      Normalized : constant String := Version.Files.Normalize_Separators (Url);
   begin
      if Normalized'Length = 0 then
         return False;
      elsif Starts_With (Normalized, "./")
        or else Starts_With (Normalized, "../")
      then
         return True;
      else
         return False;
      end if;
   end Is_Relative_Submodule_Url;

   function Normalized_Relative_Submodule_Url (Url : String) return String is
      Normalized : constant String := Version.Files.Normalize_Separators (Url);
   begin
      if Url'Length = 0 or else Contains_Control (Url) then
         raise Ada.IO_Exceptions.Data_Error
           with "unsafe relative submodule URL";
      end if;

      if not Is_Relative_Submodule_Url (Normalized) then
         return Url;
      end if;

      if Ada.Strings.Fixed.Index (Normalized, "//") /= 0 then
         raise Ada.IO_Exceptions.Data_Error
           with "unsafe relative submodule URL empty path component";
      end if;

      return Normalized;
   end Normalized_Relative_Submodule_Url;

   function Directory_Name_For_Url_Path (Path : String) return String is
      Last  : Natural := Path'Last;
      Slash : Natural := 0;
   begin
      if Path'Length = 0 then
         return "";
      end if;

      while Last > Path'First and then Path (Last) = '/' loop
         Last := Last - 1;
      end loop;

      for I in reverse Path'First .. Last loop
         if Path (I) = '/' then
            Slash := I;
            exit;
         end if;
      end loop;

      if Slash = 0 then
         return "";
      elsif Slash = Path'First then
         return "/";
      else
         return Path (Path'First .. Slash - 1);
      end if;
   end Directory_Name_For_Url_Path;

   function Append_Relative_And_Normalize
     (Base_Dir, Relative : String) return String is
   begin
      if Base_Dir'Length = 0 then
         return Lexically_Normalized_Path (Relative);
      elsif Base_Dir = "/" then
         return Lexically_Normalized_Path ("/" & Relative);
      else
         return Lexically_Normalized_Path (Base_Dir & "/" & Relative);
      end if;
   end Append_Relative_And_Normalize;

   function Relative_Path_Escapes_Base
     (Base_Dir : String; Relative : String) return Boolean
   is
      Base  : constant String := Lexically_Normalized_Path (Base_Dir);
      Rel   : constant String := Version.Files.Normalize_Separators (Relative);
      Depth : Natural := 0;
      First : Natural := Base'First;

      procedure Count_Base_Segment (Segment : String) is
      begin
         if Segment'Length = 0 or else Segment = "." then
            return;
         elsif Segment = ".." then
            if Depth > 0 then
               Depth := Depth - 1;
            end if;
         else
            Depth := Depth + 1;
         end if;
      end Count_Base_Segment;

      procedure Apply_Relative_Segment
        (Segment : String; Escaped : in out Boolean) is
      begin
         if Segment'Length = 0 or else Segment = "." then
            return;
         elsif Segment = ".." then
            if Depth = 0 then
               Escaped := True;
            else
               Depth := Depth - 1;
            end if;
         else
            Depth := Depth + 1;
         end if;
      end Apply_Relative_Segment;

      Escaped : Boolean := False;
   begin
      while First <= Base'Last loop
         while First <= Base'Last and then Base (First) = '/' loop
            First := First + 1;
         end loop;

         exit when First > Base'Last;

         declare
            Last : Natural := First;
         begin
            while Last <= Base'Last and then Base (Last) /= '/' loop
               Last := Last + 1;
            end loop;

            Count_Base_Segment (Base (First .. Last - 1));
            First := Last + 1;
         end;
      end loop;

      First := Rel'First;
      while First <= Rel'Last loop
         while First <= Rel'Last and then Rel (First) = '/' loop
            First := First + 1;
         end loop;

         exit when First > Rel'Last or else Escaped;

         declare
            Last : Natural := First;
         begin
            while Last <= Rel'Last and then Rel (Last) /= '/' loop
               Last := Last + 1;
            end loop;

            Apply_Relative_Segment (Rel (First .. Last - 1), Escaped);
            First := Last + 1;
         end;
      end loop;

      return Escaped;
   end Relative_Path_Escapes_Base;

   function Default_Remote_Url return String is
      Remotes   : constant Version.Remotes.Remote_Vectors.Vector :=
        Version.Remotes.List_Remotes;
      First_Url : Unbounded_String := Null_Unbounded_String;
   begin
      if Remotes.Is_Empty then
         return "";
      end if;

      for I in Remotes.First_Index .. Remotes.Last_Index loop
         declare
            Name : constant String := To_String (Remotes.Element (I).Name);
            Url  : constant String := To_String (Remotes.Element (I).Url);
         begin
            if Length (First_Url) = 0 then
               First_Url := To_Unbounded_String (Url);
            end if;

            if Name = "origin" then
               return Url;
            end if;
         end;
      end loop;

      return To_String (First_Url);
   end Default_Remote_Url;

   function Resolve_Relative_Submodule_Url
     (Relative_Url : String; Base_Url : String) return String
   is
      Scheme_Pos          : Natural;
      After_Authority     : Natural := 0;
      Colon               : Natural;
      Normalized_Relative : constant String :=
        Normalized_Relative_Submodule_Url (Relative_Url);
   begin
      if not Is_Relative_Submodule_Url (Normalized_Relative) then
         return Normalized_Relative;
      end if;

      if Base_Url'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error
           with
             "relative submodule URL requires a configured superproject remote";
      end if;

      if Contains_Control (Base_Url) then
         raise Ada.IO_Exceptions.Data_Error
           with "unsafe superproject remote URL";
      end if;

      Scheme_Pos := Ada.Strings.Fixed.Index (Base_Url, "://");
      if Scheme_Pos /= 0 then
         declare
            Prefix_End : constant Natural := Scheme_Pos + 2;
         begin
            After_Authority := 0;
            for I in Prefix_End + 1 .. Base_Url'Last loop
               if Base_Url (I) = '/' then
                  After_Authority := I;
                  exit;
               end if;
            end loop;

            if After_Authority = 0 then
               raise Ada.IO_Exceptions.Data_Error
                 with
                   "relative submodule URL requires a path-bearing superproject remote";
            end if;

            declare
               Prefix        : constant String :=
                 Base_Url (Base_Url'First .. After_Authority - 1);
               Base_Path     : constant String :=
                 Base_Url (After_Authority .. Base_Url'Last);
               Resolved_Path : constant String :=
                 Append_Relative_And_Normalize
                   (Directory_Name_For_Url_Path (Base_Path),
                    Normalized_Relative);
            begin
               if Relative_Path_Escapes_Base
                    (Directory_Name_For_Url_Path (Base_Path),
                     Normalized_Relative)
                 or else Resolved_Path'Length = 0
                 or else Resolved_Path (Resolved_Path'First) /= '/'
               then
                  raise Ada.IO_Exceptions.Data_Error
                    with "relative submodule URL escapes remote root";
               end if;

               return Prefix & Resolved_Path;
            end;
         end;
      elsif Has_Scp_Like_Separator (Base_Url) then
         Colon := Ada.Strings.Fixed.Index (Base_Url, ":");
         declare
            Prefix        : constant String :=
              Base_Url (Base_Url'First .. Colon);
            Base_Path     : constant String :=
              Base_Url (Colon + 1 .. Base_Url'Last);
            Base_Dir      : constant String :=
              Directory_Name_For_Url_Path (Base_Path);
            Resolved_Path : constant String :=
              Append_Relative_And_Normalize (Base_Dir, Normalized_Relative);
         begin
            if Relative_Path_Escapes_Base (Base_Dir, Normalized_Relative)
              or else Resolved_Path'Length = 0
              or else Starts_With (Resolved_Path, "../")
              or else Resolved_Path = ".."
              or else Starts_With (Resolved_Path, "/")
            then
               raise Ada.IO_Exceptions.Data_Error
                 with "relative submodule URL escapes SSH remote path";
            end if;

            return Prefix & Resolved_Path;
         end;
      else
         declare
            Base_Path     : constant String :=
              Version.Transport.Strip_File_Scheme (Base_Url);
            Base_Dir      : constant String :=
              Directory_Name_For_Url_Path (Base_Path);
            Resolved_Path : constant String :=
              Append_Relative_And_Normalize (Base_Dir, Normalized_Relative);
         begin
            if Relative_Path_Escapes_Base (Base_Dir, Normalized_Relative)
              or else Resolved_Path'Length = 0
              or else
                (Base_Path'Length > 0
                 and then Base_Path (Base_Path'First) = '/'
                 and then not Starts_With (Resolved_Path, "/"))
            then
               raise Ada.IO_Exceptions.Data_Error
                 with "relative submodule URL escapes local remote root";
            end if;

            if Starts_With (Base_Url, "file://") then
               return "file://" & Resolved_Path;
            else
               return Resolved_Path;
            end if;
         end;
      end if;
   end Resolve_Relative_Submodule_Url;

   function Resolve_Relative_Submodule_Url
     (Relative_Url : String) return String is
   begin
      return
        Resolve_Relative_Submodule_Url
          (Relative_Url => Relative_Url, Base_Url => Default_Remote_Url);
   end Resolve_Relative_Submodule_Url;

   function Is_Unsupported_Relative_Submodule_Url (Url : String) return Boolean
   is
      File_Prefix : constant String := "file://";
   begin
      if Url'Length = 0 then
         return True;
      elsif Is_Relative_Submodule_Url (Url) then
         return False;
      elsif Starts_With (Url, File_Prefix) then
         declare
            Path_Text : constant String :=
              Url (Url'First + File_Prefix'Length .. Url'Last);
         begin
            return
              Path_Text'Length = 0
              or else
                (Path_Text (Path_Text'First) /= '/'
                 and then not Is_Windows_Drive_Like_Path (Path_Text));
         end;
      elsif Has_Scheme (Url) or else Has_Scp_Like_Separator (Url) then
         return False;
      elsif Url (Url'First) = '/' or else Is_Windows_Drive_Like_Path (Url) then
         return False;
      else
         return True;
      end if;
   end Is_Unsupported_Relative_Submodule_Url;

   procedure Absorb_Clone_Gitdir
     (Repo : Version.Repository.Repository_Handle; Path : String)
   is
      Work_Path      : constant String := Submodule_Worktree_Path (Repo, Path);
      Dot_Git        : constant String := Join (Work_Path, ".git");
      Admin          : constant String := Submodule_Admin_Path (Repo, Path);
      Native_Dot_Git : constant String :=
        Version.Files.To_Native_Path (Dot_Git);
      Native_Admin   : constant String := Version.Files.To_Native_Path (Admin);
   begin
      if not Ada.Directories.Exists (Native_Dot_Git) then
         return;
      end if;

      if Ada.Directories.Kind (Native_Dot_Git) /= Ada.Directories.Directory
      then
         return;
      end if;

      if Ada.Directories.Exists (Native_Admin) then
         return;
      end if;

      Version.Files.Rename_Directory (Dot_Git, Admin);
      Version.Files.Write_Binary_File_Atomic
        (Path => Dot_Git, Content => "gitdir: " & Admin & Character'Val (10));
   end Absorb_Clone_Gitdir;

   procedure Require_Submodule_Repository
     (Repo : Version.Repository.Repository_Handle; Path : String)
   is
      Work_Path : constant String := Submodule_Worktree_Path (Repo, Path);
      Dot_Git   : constant String := Join (Work_Path, ".git");
   begin
      if not Ada.Directories.Exists (Version.Files.To_Native_Path (Dot_Git))
      then
         raise Ada.IO_Exceptions.Data_Error
           with "submodule worktree is not a repository: " & Path;
      end if;
   end Require_Submodule_Repository;

   function Read_Gitdir_File (Git_File : String) return String is
      Prefix : constant String := "gitdir:";
      Text   : constant String := Version.Files.Read_Binary_File (Git_File);
      Last   : Natural := Text'First;
   begin
      while Last <= Text'Last
        and then Text (Last) /= Character'Val (10)
        and then Text (Last) /= Character'Val (13)
      loop
         Last := Last + 1;
      end loop;

      declare
         Line : constant String :=
           (if Last > Text'First then Text (Text'First .. Last - 1) else "");
      begin
         if Line'Length <= Prefix'Length
           or else
             Line (Line'First .. Line'First + Prefix'Length - 1) /= Prefix
         then
            raise Ada.IO_Exceptions.Data_Error
              with "invalid submodule .git file";
         end if;

         declare
            Start : Natural := Line'First + Prefix'Length;
         begin
            while Start <= Line'Last
              and then
                (Line (Start) = ' ' or else Line (Start) = Character'Val (9))
            loop
               Start := Start + 1;
            end loop;

            if Start > Line'Last then
               raise Ada.IO_Exceptions.Data_Error
                 with "empty submodule gitdir";
            end if;

            return Trim_Horizontal (Line (Start .. Line'Last));
         end;
      end;
   end Read_Gitdir_File;

   function Resolved_Submodule_Git_Dir
     (Repo : Version.Repository.Repository_Handle; Path : String) return String
   is
      Work_Path : constant String := Submodule_Worktree_Path (Repo, Path);
      Dot_Git   : constant String := Join (Work_Path, ".git");
      Modules   : constant String := Submodule_Admin_Root (Repo);
   begin
      if not Ada.Directories.Exists (Version.Files.To_Native_Path (Work_Path))
      then
         return "";
      end if;

      if not Ada.Directories.Exists (Version.Files.To_Native_Path (Dot_Git))
      then
         return "";
      end if;

      if Ada.Directories.Kind (Version.Files.To_Native_Path (Dot_Git))
        = Ada.Directories.Directory
      then
         return Dot_Git;
      end if;

      declare
         Raw      : constant String := Read_Gitdir_File (Dot_Git);
         Resolved : constant String := Absolute_Gitdir (Work_Path, Raw);
      begin
         if not Same_Or_Under (Modules, Resolved) then
            raise Ada.IO_Exceptions.Data_Error
              with "submodule gitdir escapes modules directory: " & Path;
         end if;

         if not Ada.Directories.Exists
                  (Version.Files.To_Native_Path (Resolved))
           or else
             Ada.Directories.Kind (Version.Files.To_Native_Path (Resolved))
             /= Ada.Directories.Directory
         then
            raise Ada.IO_Exceptions.Data_Error
              with "submodule gitdir target does not exist: " & Path;
         end if;

         return Resolved;
      end;
   end Resolved_Submodule_Git_Dir;

   function Packed_Ref_Id
     (Sub_Git_Dir : String; Ref_Name : String) return String
   is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open_Git_Dir (Sub_Git_Dir);
      Refs : constant Version.Packed_Refs.Packed_Ref_Vectors.Vector :=
        Version.Packed_Refs.Read_All (Repo);
   begin
      if Refs.Is_Empty then
         return "";
      end if;

      for I in Refs.First_Index .. Refs.Last_Index loop
         if Ada.Strings.Unbounded.To_String (Refs.Element (I).Name) = Ref_Name then
            return To_String (Refs.Element (I).Id);
         end if;
      end loop;

      return "";
   end Packed_Ref_Id;

   function Submodule_Head
     (Repo : Version.Repository.Repository_Handle; Path : String) return String
   is
      Sub_Git_Dir : constant String := Resolved_Submodule_Git_Dir (Repo, Path);
   begin
      if Sub_Git_Dir'Length = 0 then
         return "";
      end if;

      declare
         Head_Path : constant String := Join (Sub_Git_Dir, "HEAD");
      begin
         if not Ada.Directories.Exists
                  (Version.Files.To_Native_Path (Head_Path))
         then
            return "";
         end if;

         declare
            Head_Text  : constant String :=
              Trim_Horizontal
                (First_Line (Version.Files.Read_Binary_File (Head_Path)));
            Ref_Prefix : constant String := "ref:";
         begin
            if Version.Objects.Is_Valid_Hex_Object_Id (Head_Text) then
               return Head_Text;
            elsif Starts_With (Head_Text, Ref_Prefix)
              and then Head_Text'Length > Ref_Prefix'Length
            then
               declare
                  Ref_Name : constant String :=
                    Trim_Horizontal
                      (Head_Text
                         (Head_Text'First
                          + Ref_Prefix'Length
                          .. Head_Text'Last));
                  Ref_Path : constant String := Join (Sub_Git_Dir, Ref_Name);
               begin
                  if Ref_Name'Length = 0 then
                     return "";
                  end if;

                  Version.Path_Safety.Require_Safe_Relative_Path
                    (Ref_Name, "submodule HEAD ref");

                  if Ada.Directories.Exists
                       (Version.Files.To_Native_Path (Ref_Path))
                  then
                     declare
                        Ref_Text : constant String :=
                          First_Line
                            (Version.Files.Read_Binary_File (Ref_Path));
                     begin
                        if Version.Objects.Is_Valid_Hex_Object_Id (Ref_Text)
                        then
                           return Ref_Text;
                        end if;
                     end;
                  end if;

                  declare
                     Packed_Id : constant String :=
                       Packed_Ref_Id (Sub_Git_Dir, Ref_Name);
                  begin
                     if Packed_Id'Length > 0 then
                        return Packed_Id;
                     end if;
                  end;
               end;
            end if;

            return "";
         end;
      end;
   end Submodule_Head;

   procedure Checkout_Detached
     (Repo   : Version.Repository.Repository_Handle;
      Path   : String;
      Commit : Version.Objects.Hex_Object_Id)
   is
      Work_Path : constant String := Submodule_Worktree_Path (Repo, Path);

      procedure Do_Checkout is
         Sub_Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;

         function Commit_Tree_After_Optional_Fetch
            return Version.Objects.Hex_Object_Id is
         begin
            return
              Version.Objects.Commit_Tree_Id
                (Version.Objects.Read_Object (Sub_Repo, Commit));
         exception
            when Ada.IO_Exceptions.Name_Error | Ada.IO_Exceptions.Data_Error =>
               Version.Fetch.Fetch ("origin");
               return
                 Version.Objects.Commit_Tree_Id
                   (Version.Objects.Read_Object (Sub_Repo, Commit));
         end Commit_Tree_After_Optional_Fetch;
      begin
         if Version.Files.Normalize_Separators
              (Version.Repository.Root_Path (Sub_Repo))
           /= Version.Files.Normalize_Separators (Work_Path)
         then
            raise Ada.IO_Exceptions.Data_Error
              with "submodule worktree is not a repository: " & Path;
         end if;

         declare
            Tree_Id : constant Version.Objects.Hex_Object_Id :=
              Commit_Tree_After_Optional_Fetch;
         begin
            Version.Refs.Write_Detached_HEAD (Sub_Repo, Commit);
            Version.Restore.Restore_Working_Tree (Sub_Repo);
            Version.Staging.Write_From_Tree
              (Repo => Sub_Repo, Tree_Id => Tree_Id);
         end;
      end Do_Checkout;

   begin
      Normalize_Submodule_Gitdir_File (Repo, Path);
      Version.Files.With_Directory
        (Path => Work_Path, Action => Do_Checkout'Access);
   end Checkout_Detached;

   procedure Clone_One
     (Repo      : Version.Repository.Repository_Handle;
      Item      : Version.Gitmodules.Submodule_Config;
      Recursive : Boolean)
   is
      Path      : constant String := To_String (Item.Path);
      Raw_Url   : constant String := To_String (Item.Url);
      Url       : constant String := Resolve_Relative_Submodule_Url (Raw_Url);
      Work_Path : constant String := Submodule_Worktree_Path (Repo, Path);
      Expected  : constant Version.Objects.Hex_Object_Id :=
        Gitlink_Commit (Repo, Path);
   begin
      if Url'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error
           with "submodule url must not be empty: " & Path;
      end if;

      if Is_Unsupported_Relative_Submodule_Url (Url) then
         raise Ada.IO_Exceptions.Data_Error
           with "unsupported relative submodule URL: " & Url;
      end if;

      if Version.Transport.Detect_Transport (Url)
        = Version.Transport.Unsupported_Transport
      then
         raise Ada.IO_Exceptions.Data_Error
           with "unsupported submodule URL: " & Url;
      end if;

      Version.Filesystem_Guard.Require_Safe_Write_Target
        (Repo_Root     => Version.Repository.Root_Path (Repo),
         Relative_Path => Path,
         Is_Directory  => True);

      if not Ada.Directories.Exists (Version.Files.To_Native_Path (Work_Path))
      then
         Version.Clone.Clone (Source => Url, Target => Work_Path);
         Absorb_Clone_Gitdir (Repo, Path);
      end if;

      Require_Submodule_Repository (Repo, Path);
      Checkout_Detached (Repo, Path, Expected);

      if Recursive then
         declare
            procedure Recurse is
               Sub_Repo : constant Version.Repository.Repository_Handle :=
                 Version.Repository.Open;
            begin
               Update (Sub_Repo, Recursive => True);
            end Recurse;
         begin
            Version.Files.With_Directory
              (Path => Work_Path, Action => Recurse'Access);
         end;
      end if;
   end Clone_One;

   procedure Preflight_Submodule_Paths
     (Repo        : Version.Repository.Repository_Handle;
      Items       : Version.Gitmodules.Submodule_Config_Vectors.Vector;
      Active_Only : Boolean := False)
   is
      Planned : Version.Filesystem_Guard.Planned_Path_Vectors.Vector;
   begin
      if Items.Is_Empty then
         return;
      end if;

      for I in Items.First_Index .. Items.Last_Index loop
         declare
            Path : constant String := To_String (Items.Element (I).Path);
         begin
            Version.Path_Safety.Require_Safe_Relative_Path
              (Path, "submodule path");

            if (not Active_Only) or else Version.Sparse.Included (Repo, Path)
            then
               Planned.Append
                 (Planned_Path'
                    (Path         => To_Unbounded_String (Path),
                     Is_Directory => True,
                     Is_Symlink   => False));
            end if;
         end;
      end loop;

      Version.Filesystem_Guard.Preflight_Checkout
        (Repo_Root => Version.Repository.Root_Path (Repo), Paths => Planned);
   end Preflight_Submodule_Paths;

   procedure Init (Repo : Version.Repository.Repository_Handle) is
      Items : constant Version.Gitmodules.Submodule_Config_Vectors.Vector :=
        Version.Gitmodules.Read (Repo);
   begin
      Preflight_Submodule_Paths
        (Repo => Repo, Items => Items, Active_Only => False);

      Version.Files.Create_Directory_If_Missing (Submodule_Admin_Root (Repo));
   end Init;

   procedure Init is
   begin
      Init (Version.Repository.Open);
   end Init;

   procedure Update
     (Repo      : Version.Repository.Repository_Handle;
      Recursive : Boolean := False)
   is
      Items : constant Version.Gitmodules.Submodule_Config_Vectors.Vector :=
        Version.Gitmodules.Read (Repo);
   begin
      if Items.Is_Empty then
         return;
      end if;

      Preflight_Submodule_Paths
        (Repo => Repo, Items => Items, Active_Only => True);

      for I in Items.First_Index .. Items.Last_Index loop
         declare
            Path : constant String := To_String (Items.Element (I).Path);
         begin
            if Version.Sparse.Included (Repo, Path) then
               Clone_One (Repo, Items.Element (I), Recursive);
            end if;
         end;
      end loop;
   end Update;

   procedure Update (Recursive : Boolean := False) is
   begin
      Update (Version.Repository.Open, Recursive);
   end Update;

   procedure Clone_Recursive (Url : String; Target : String) is
   begin
      Version.Clone.Clone (Source => Url, Target => Target);
      declare
         procedure Do_Update is
         begin
            Update (Version.Repository.Open, Recursive => True);
         end Do_Update;
      begin
         Version.Files.With_Directory
           (Path => Target, Action => Do_Update'Access);
      end;
   end Clone_Recursive;

   function Submodule_Is_Dirty
     (Repo : Version.Repository.Repository_Handle; Path : String)
      return Boolean
   is
      Work_Path : constant String := Submodule_Worktree_Path (Repo, Path);
      Result    : Boolean := False;

      procedure Check is
         Status_Result : constant Version.Status.Status_Result :=
           Version.Status.Current_Status;
      begin
         Result :=
           not Status_Result.Changes.Is_Empty
           or else not Status_Result.Staged.Is_Empty
           or else not Status_Result.Untracked.Is_Empty
           or else not Status_Result.Conflicted.Is_Empty;
      end Check;
   begin
      if Submodule_Head (Repo, Path)'Length = 0 then
         return False;
      end if;

      Normalize_Submodule_Gitdir_File (Repo, Path);

      Version.Files.With_Directory (Path => Work_Path, Action => Check'Access);
      return Result;
   exception
      when others =>
         return False;
   end Submodule_Is_Dirty;

   function Statuses
     (Repo : Version.Repository.Repository_Handle)
      return Submodule_Status_Vectors.Vector
   is
      Items  : Version.Gitmodules.Submodule_Config_Vectors.Vector;
      Result : Submodule_Status_Vectors.Vector;
   begin
      Validate_Committed_Gitmodules (Repo);
      Items := Version.Gitmodules.Read (Repo);

      if not Items.Is_Empty then
         for I in Items.First_Index .. Items.Last_Index loop
            declare
               Path : constant String := To_String (Items.Element (I).Path);
            begin
               --  Sparse checkout may intentionally omit a submodule path.
               --  Treat that as absent from the active working tree view rather
               --  than reporting a missing checkout.
               if Version.Sparse.Included (Repo, Path) then
                  declare
                     Expected : constant Version.Objects.Hex_Object_Id :=
                       Gitlink_Commit (Repo, Path);
                     Actual   : constant String := Submodule_Head (Repo, Path);
                     Kind     : Submodule_Status_Kind := Submodule_Clean;
                  begin
                     if Actual'Length = 0 then
                        Kind := Submodule_Missing;
                     elsif Actual /= To_String (Expected) then
                        Kind := Submodule_New_Commits;
                     elsif Submodule_Is_Dirty (Repo, Path) then
                        Kind := Submodule_Dirty;
                     else
                        Kind := Submodule_Clean;
                     end if;

                     Result.Append
                       (Submodule_Status'
                          (Path     => To_Unbounded_String (Path),
                           Expected => Expected,
                           Actual   => To_Unbounded_String (Actual),
                           Kind     => Kind));
                  end;
               end if;
            end;
         end loop;
      end if;

      return Result;
   end Statuses;

   function Status_Kind_Label (Kind : Submodule_Status_Kind) return String is
   begin
      case Kind is
         when Submodule_Missing     =>
            return "missing";

         when Submodule_Clean       =>
            return "clean";

         when Submodule_New_Commits =>
            return "new commits";

         when Submodule_Dirty       =>
            return "dirty";
      end case;
   end Status_Kind_Label;

   function Status_Line (Item : Submodule_Status) return String is
      Actual   : constant String := To_String (Item.Actual);
      Path     : constant String := To_String (Item.Path);
      Expected : constant String := To_String (Item.Expected);
   begin
      case Item.Kind is
         when Submodule_Missing     =>
            return "-" & Expected & " " & Path & " (missing)";

         when Submodule_Clean       =>
            return " " & Expected & " " & Path & " (clean)";

         when Submodule_New_Commits =>
            return
              "+"
              & Actual
              & " "
              & Path
              & " (new commits; expected "
              & Expected
              & ")";

         when Submodule_Dirty       =>
            return "!" & Actual & " " & Path & " (dirty)";
      end case;
   end Status_Line;

   procedure Status is
      Repo  : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
      Items : constant Submodule_Status_Vectors.Vector := Statuses (Repo);
   begin
      if Items.Is_Empty then
         Ada.Text_IO.Put_Line ("no submodules");
         return;
      end if;

      for I in Items.First_Index .. Items.Last_Index loop
         Ada.Text_IO.Put_Line (Status_Line (Items.Element (I)));
      end loop;
   end Status;

   function Less_By_Path
     (Left, Right : Version.Gitmodules.Submodule_Config) return Boolean is
     (To_String (Left.Path) < To_String (Right.Path));

   package Submodule_Sorting is new
     Version.Gitmodules.Submodule_Config_Vectors.Generic_Sorting (Less_By_Path);

   --  The configured submodules, sorted by path as git iterates them.
   function Sorted_Submodules
     (Repo : Version.Repository.Repository_Handle)
      return Version.Gitmodules.Submodule_Config_Vectors.Vector
   is
      Items : Version.Gitmodules.Submodule_Config_Vectors.Vector :=
        Version.Gitmodules.Read (Repo);
   begin
      Submodule_Sorting.Sort (Items);
      return Items;
   end Sorted_Submodules;

   --  True when the submodule path is one the operation targets: any path in
   --  the (normalized) selection, or every submodule when the selection is
   --  empty and All_Submodules is requested.
   function Path_Selected
     (Path           : String;
      Paths          : Path_Vectors.Vector;
      All_Submodules : Boolean) return Boolean is
   begin
      if All_Submodules then
         return True;
      end if;
      for P of Paths loop
         if Canonical_Submodule_Path (P) = Canonical_Submodule_Path (Path) then
            return True;
         end if;
      end loop;
      return False;
   end Path_Selected;

   procedure Foreach
     (Repo      : Version.Repository.Repository_Handle;
      Command   : String;
      Recursive : Boolean := False)
   is
      Items    : constant Version.Gitmodules.Submodule_Config_Vectors.Vector :=
        Sorted_Submodules (Repo);
      Toplevel : constant String :=
        Ada.Directories.Full_Name
          (Version.Files.To_Native_Path (Version.Repository.Root_Path (Repo)));
   begin
      for I in Items.First_Index .. Items.Last_Index loop
         declare
            Name : constant String := To_String (Items.Element (I).Name);
            Path : constant String := To_String (Items.Element (I).Path);
         begin
            --  Only populated, active submodules are visited (git skips ones
            --  that are not checked out).
            if Version.Sparse.Included (Repo, Path)
              and then Submodule_Head (Repo, Path)'Length > 0
            then
               declare
                  Work : constant String := Submodule_Worktree_Path (Repo, Path);
                  Sha  : constant String :=
                    To_String (Gitlink_Commit (Repo, Path));
               begin
                  Ada.Text_IO.Put_Line ("Entering '" & Path & "'");

                  Ada.Environment_Variables.Set ("name", Name);
                  Ada.Environment_Variables.Set ("sm_path", Path);
                  Ada.Environment_Variables.Set ("displaypath", Path);
                  Ada.Environment_Variables.Set ("sha1", Sha);
                  Ada.Environment_Variables.Set ("toplevel", Toplevel);

                  declare
                     Old_Dir : constant String :=
                       Ada.Directories.Current_Directory;
                     Args    : GNAT.OS_Lib.Argument_List :=
                       [1 => new String'("-c"), 2 => new String'(Command)];
                     Status  : Integer;
                  begin
                     Ada.Directories.Set_Directory
                       (Version.Files.To_Native_Path (Work));
                     Status := GNAT.OS_Lib.Spawn ("/bin/sh", Args);
                     Ada.Directories.Set_Directory (Old_Dir);
                     GNAT.OS_Lib.Free (Args (1));
                     GNAT.OS_Lib.Free (Args (2));

                     if Status /= 0 then
                        raise Ada.IO_Exceptions.Data_Error with
                          "run_command returned non-zero status for '"
                          & Path & "'";
                     end if;
                  end;

                  if Recursive then
                     declare
                        procedure Recurse is
                        begin
                           Foreach
                             (Version.Repository.Open, Command,
                              Recursive => True);
                        end Recurse;
                     begin
                        Version.Files.With_Directory (Work, Recurse'Access);
                     end;
                  end if;
               end;
            end if;
         end;
      end loop;
   end Foreach;

   procedure Foreach (Command : String; Recursive : Boolean := False) is
   begin
      Foreach (Version.Repository.Open, Command, Recursive);
   end Foreach;

   --  Resolve a .gitmodules URL for storing in config: relative URLs are
   --  resolved against the superproject remote, absolute URLs pass through.
   function Sync_Url (Raw : String) return String is
   begin
      return Resolve_Relative_Submodule_Url (Raw);
   exception
      when others =>
         return Raw;
   end Sync_Url;

   procedure Sync
     (Repo      : Version.Repository.Repository_Handle;
      Recursive : Boolean := False)
   is
      Items : constant Version.Gitmodules.Submodule_Config_Vectors.Vector :=
        Sorted_Submodules (Repo);
   begin
      for I in Items.First_Index .. Items.Last_Index loop
         declare
            Name     : constant String := To_String (Items.Element (I).Name);
            Path     : constant String := To_String (Items.Element (I).Path);
            Resolved : constant String :=
              Sync_Url (To_String (Items.Element (I).Url));
         begin
            Ada.Text_IO.Put_Line
              ("Synchronizing submodule url for '" & Path & "'");

            Version.Config.Set_Key
              (Repo, "submodule." & Name & ".url", Resolved);

            --  Update the submodule's own origin URL when it is checked out.
            if Submodule_Head (Repo, Path)'Length > 0 then
               begin
                  declare
                     Sub : constant Version.Repository.Repository_Handle :=
                       Version.Repository.Open_Git_Dir
                         (Resolved_Submodule_Git_Dir (Repo, Path));
                  begin
                     Version.Config.Set_Key
                       (Sub, "remote.origin.url", Resolved);
                  end;
               exception
                  when others =>
                     null;
               end;

               if Recursive then
                  declare
                     procedure Recurse is
                     begin
                        Sync (Version.Repository.Open, Recursive => True);
                     end Recurse;
                  begin
                     Version.Files.With_Directory
                       (Submodule_Worktree_Path (Repo, Path), Recurse'Access);
                  end;
               end if;
            end if;
         end;
      end loop;
   end Sync;

   procedure Sync (Recursive : Boolean := False) is
   begin
      Sync (Version.Repository.Open, Recursive);
   end Sync;

   procedure Deinit
     (Repo           : Version.Repository.Repository_Handle;
      Paths          : Path_Vectors.Vector;
      All_Submodules : Boolean := False;
      Force          : Boolean := False)
   is
      Items : constant Version.Gitmodules.Submodule_Config_Vectors.Vector :=
        Sorted_Submodules (Repo);

      function Registered_Url (Name, Fallback : String) return String is
      begin
         return Version.Config.Get_Value (Repo, "submodule." & Name & ".url");
      exception
         when others =>
            return Fallback;
      end Registered_Url;
   begin
      if not All_Submodules and then Paths.Is_Empty then
         raise Ada.IO_Exceptions.Data_Error with
           "Use '--all' if you really want to deinitialize all submodules";
      end if;

      for I in Items.First_Index .. Items.Last_Index loop
         declare
            Name : constant String := To_String (Items.Element (I).Name);
            Path : constant String := To_String (Items.Element (I).Path);
         begin
            if Path_Selected (Path, Paths, All_Submodules) then
               declare
                  Url : constant String :=
                    Registered_Url (Name, To_String (Items.Element (I).Url));
               begin
                  if Submodule_Head (Repo, Path)'Length > 0 then
                     if not Force and then Submodule_Is_Dirty (Repo, Path) then
                        raise Ada.IO_Exceptions.Data_Error with
                          "submodule work tree '" & Path
                          & "' contains local modifications;"
                          & " use --force to discard them";
                     end if;

                     declare
                        Work : constant String :=
                          Submodule_Worktree_Path (Repo, Path);
                     begin
                        Version.Files.Delete_Directory_Tree_If_Exists (Work);
                        Version.Files.Create_Directory_If_Missing (Work);
                     end;
                     Ada.Text_IO.Put_Line ("Cleared directory '" & Path & "'");
                  end if;

                  Version.Config.Remove_Section
                    (Repo, "submodule """ & Name & """");
                  Ada.Text_IO.Put_Line
                    ("Submodule '" & Name & "' (" & Url
                     & ") unregistered for path '" & Path & "'");
               end;
            end if;
         end;
      end loop;
   end Deinit;

   procedure Deinit
     (Paths          : Path_Vectors.Vector;
      All_Submodules : Boolean := False;
      Force          : Boolean := False) is
   begin
      Deinit (Version.Repository.Open, Paths, All_Submodules, Force);
   end Deinit;

   procedure Stage_Submodule
     (Repo : Version.Repository.Repository_Handle; Path : String)
   is
      Safe_Path : constant String := Canonical_Submodule_Path (Path);
      Head      : constant String := Submodule_Head (Repo, Safe_Path);
      Entries   : Version.Staging.Index_Entry_Vectors.Vector :=
        Version.Staging.Load (Repo);
      Pos       : constant Natural :=
        Version.Staging.Find_Path (Entries, Safe_Path);
   begin
      if Pos = Natural'Last
        or else To_String (Entries.Element (Pos).Mode) /= "160000"
      then
         raise Ada.IO_Exceptions.Data_Error
           with "submodule path is not tracked as gitlink: " & Safe_Path;
      end if;

      if Head'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error
           with "submodule is not checked out: " & Safe_Path;
      end if;

      if not Version.Objects.Is_Valid_Hex_Object_Id (Head) then
         raise Ada.IO_Exceptions.Data_Error
           with "invalid submodule HEAD: " & Safe_Path;
      end if;

      Version.Staging.Replace_Entry
        (Entries,
         Version.Staging.Index_Entry'
           (Path => To_Unbounded_String (Safe_Path),
            Id   => Version.Objects.To_Object_Id (Head),
            Mode => To_Unbounded_String ("160000"),
            Stage => 0, Skip_Worktree => False));
      Version.Staging.Sort_By_Path (Entries);
      Version.Staging.Write (Repo => Repo, Entries => Entries);
   end Stage_Submodule;

end Version.Submodules;
