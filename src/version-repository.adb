with Ada.Directories; use Ada.Directories;
with Ada.Strings.Fixed;
with Version.Files;
with Version.Availability;
with Version.Platform;
with Version.Repository_Format;
with Version.Transport.Local;

package body Version.Repository is

   function Parent_Of (Path : String) return String is
   begin
      return Ada.Directories.Containing_Directory (Path);
   exception
      when Ada.Directories.Name_Error | Ada.Directories.Use_Error =>
         return Path;
   end Parent_Of;

   function Join (Left, Right : String) return String renames Version.Files.Join;

   function Same_Path (Left, Right : String) return Boolean is
   begin
      return Version.Files.Normalize_Separators (Left) =
        Version.Files.Normalize_Separators (Right);
   end Same_Path;

   function Contains_Dot_Path_Component (Path : String) return Boolean is
      Start : Positive := Path'First;
   begin
      while Start <= Path'Last loop
         declare
            Stop : Natural := Start;
         begin
            while Stop <= Path'Last and then Path (Stop) /= '/' loop
               Stop := Stop + 1;
            end loop;

            declare
               Component : constant String :=
                 (if Stop = Start then "" else Path (Start .. Stop - 1));
            begin
               if Component = "." or else Component = ".." then
                  return True;
               end if;
            end;

            Start := Stop + 1;
         end;
      end loop;

      return False;
   end Contains_Dot_Path_Component;

   function Resolve_Gitdir_Text
     (Base_Dir : String;
      Text     : String;
      Context  : String;
      Allow_Dot_Dot : Boolean := False)
      return String
   is
      Value : constant String :=
        Ada.Strings.Fixed.Trim (Text, Ada.Strings.Both);
      Normal_Value : constant String :=
        Version.Files.Normalize_Separators (Value);
   begin
      if Value'Length = 0 then
         raise Ada.Directories.Name_Error with
           "unsupported repository: empty " & Context;
      end if;

      for C of Value loop
         if Character'Pos (C) < 32 or else Character'Pos (C) = 127 then
            raise Ada.Directories.Name_Error with
              "unsupported repository: unsafe " & Context;
         end if;
      end loop;

      if Ada.Strings.Fixed.Index (Normal_Value, "//") /= 0
        or else (not Allow_Dot_Dot and then Contains_Dot_Path_Component (Normal_Value))
        or else (Allow_Dot_Dot
                 and then Ada.Strings.Fixed.Index (Normal_Value, "/./") /= 0)
      then
         raise Ada.Directories.Name_Error with
           "unsupported repository: unsafe " & Context;
      end if;

      if Normal_Value (Normal_Value'First) = '/'
        or else Version.Platform.Is_Windows_Drive_Path (Normal_Value)
      then
         return Normal_Value;
      else
         return Version.Files.Normalize_Separators
           (Ada.Directories.Full_Name
              (Version.Files.To_Native_Path (Join (Base_Dir, Normal_Value))));
      end if;
   end Resolve_Gitdir_Text;

   function Resolve_Git_File
     (Root : String;
      Path : String)
      return String
   is
      Prefix : constant String := "gitdir:";
      Line   : constant String := Version.Transport.Local.Read_First_Line (Path);
      Value  : Ada.Strings.Unbounded.Unbounded_String;
   begin
      if Line'Length < Prefix'Length
        or else Line (Line'First .. Line'First + Prefix'Length - 1) /= Prefix
      then
         raise Ada.Directories.Name_Error with
           "unsupported repository: .git file does not contain gitdir";
      end if;

      Value :=
        Ada.Strings.Unbounded.To_Unbounded_String
          (Line (Line'First + Prefix'Length .. Line'Last));

      declare
         --  git resolves a relative gitdir against the .git file's directory,
         --  and every submodule it creates points *upwards*
         --  (`gitdir: ../.git/modules/<name>`), as does a linked worktree.
         --  Rejecting `..` here made every git-created submodule unreadable.
         Resolved : constant String :=
           Resolve_Gitdir_Text
             (Base_Dir      => Root,
              Text          => Ada.Strings.Unbounded.To_String (Value),
              Context       => "gitdir in .git file",
              Allow_Dot_Dot => True);
      begin
         if not Ada.Directories.Exists (Version.Files.To_Native_Path (Resolved))
           or else Ada.Directories.Kind (Version.Files.To_Native_Path (Resolved)) /=
             Ada.Directories.Directory
         then
            raise Ada.Directories.Name_Error with
              "unsupported repository: gitdir target does not exist";
         end if;

         return Resolved;
      end;
   end Resolve_Git_File;

   function Resolve_Git_Dir
     (Working_Path : String)
      return String
   is
      Root    : constant String := Version.Files.Normalize_Separators (Working_Path);
      Dot_Git : constant String := Join (Root, ".git");
   begin
      if not Ada.Directories.Exists (Version.Files.To_Native_Path (Dot_Git)) then
         return "";
      end if;

      case Ada.Directories.Kind (Version.Files.To_Native_Path (Dot_Git)) is
         when Ada.Directories.Directory =>
            return Dot_Git;

         when Ada.Directories.Ordinary_File =>
            return Resolve_Git_File (Root, Dot_Git);

         when others =>
            raise Ada.Directories.Name_Error with
              "unsupported repository: .git is neither directory nor file";
      end case;
   end Resolve_Git_Dir;

   function Common_Dir_For (Git_Dir : String) return String is
      Common_Path : constant String := Join (Git_Dir, "commondir");
   begin
      if Ada.Directories.Exists (Version.Files.To_Native_Path (Common_Path))
        and then Ada.Directories.Kind (Version.Files.To_Native_Path (Common_Path)) =
          Ada.Directories.Ordinary_File
      then
         declare
            Resolved : constant String :=
              Resolve_Gitdir_Text
                (Base_Dir      => Git_Dir,
                 Text          => Version.Transport.Local.Read_First_Line (Common_Path),
                 Context       => "commondir",
                 Allow_Dot_Dot => True);
         begin
            if not Ada.Directories.Exists (Version.Files.To_Native_Path (Resolved))
              or else Ada.Directories.Kind (Version.Files.To_Native_Path (Resolved)) /=
                Ada.Directories.Directory
            then
               raise Ada.Directories.Name_Error with
                 "unsupported repository: commondir target does not exist";
            end if;

            if Ada.Directories.Simple_Name
                 (Version.Files.To_Native_Path (Parent_Of (Git_Dir))) = "worktrees"
              and then not Same_Path (Resolved, Parent_Of (Parent_Of (Git_Dir)))
            then
               raise Ada.Directories.Name_Error with
                 "unsupported repository: commondir escapes worktree admin area";
            end if;

            return Resolved;
         end;
      end if;

      return Git_Dir;
   end Common_Dir_For;

   function Open_Git_Dir
     (Git_Dir : String) return Repository_Handle
   is
      Normal_Git_Dir : constant String :=
        Version.Files.Normalize_Separators
          (Ada.Directories.Full_Name (Version.Files.To_Native_Path (Git_Dir)));
      Common : constant String := Common_Dir_For (Normal_Git_Dir);
   begin
      Version.Repository_Format.Require_Compatible
        (Git_Dir  => Common,
         Mutation => True);

      return
        (Root_Path_Value      =>
           Ada.Strings.Unbounded.To_Unbounded_String (Parent_Of (Normal_Git_Dir)),
         Git_Dir_Value        => Ada.Strings.Unbounded.To_Unbounded_String (Normal_Git_Dir),
         Common_Git_Dir_Value => Ada.Strings.Unbounded.To_Unbounded_String (Common),
         Algorithm_Value      =>
           Version.Repository_Format.Algorithm
             (Version.Repository_Format.Read (Common)));
   end Open_Git_Dir;

   function Open return Repository_Handle is
      Current : Ada.Strings.Unbounded.Unbounded_String :=
        Ada.Strings.Unbounded.To_Unbounded_String (Version.Files.Current_Directory);
   begin
      loop
         declare
            Current_Text : constant String := Ada.Strings.Unbounded.To_String (Current);
            Git          : constant String := Resolve_Git_Dir (Current_Text);
         begin
            if Git'Length > 0 then
               declare
                  Common : constant String := Common_Dir_For (Git);
               begin
                  Version.Repository_Format.Require_Compatible
                    (Git_Dir  => Common,
                     Mutation => True);

                  return
                    (Root_Path_Value        => Ada.Strings.Unbounded.To_Unbounded_String (Current_Text),
                     Git_Dir_Value          => Ada.Strings.Unbounded.To_Unbounded_String (Git),
                     Common_Git_Dir_Value   => Ada.Strings.Unbounded.To_Unbounded_String (Common),
                     Algorithm_Value        =>
                       Version.Repository_Format.Algorithm
                         (Version.Repository_Format.Read (Common)));
               end;
            end if;

            declare
               Parent : constant String := Parent_Of (Current_Text);
            begin
               if Parent = Current_Text then
                  raise Ada.Directories.Name_Error with
                    Version.Availability.No_Repository;
               end if;

               Current := Ada.Strings.Unbounded.To_Unbounded_String (Parent);
            end;
         end;
      end loop;
   end Open;

   function Root_Path
     (Repo : Repository_Handle)
      return String is
   begin
      return Ada.Strings.Unbounded.To_String (Repo.Root_Path_Value);
   end Root_Path;

   function Git_Dir
     (Repo : Repository_Handle)
      return String is
   begin
      return Ada.Strings.Unbounded.To_String (Repo.Git_Dir_Value);
   end Git_Dir;

   function Common_Git_Dir
     (Repo : Repository_Handle)
      return String is
   begin
      return Ada.Strings.Unbounded.To_String (Repo.Common_Git_Dir_Value);
   end Common_Git_Dir;

   function Is_Linked_Worktree
     (Repo : Repository_Handle)
      return Boolean is
   begin
      return Git_Dir (Repo) /= Common_Git_Dir (Repo);
   end Is_Linked_Worktree;

   function Algorithm
     (Repo : Repository_Handle)
      return Version.Hash.Hash_Algorithm is
   begin
      return Repo.Algorithm_Value;
   end Algorithm;

end Version.Repository;
