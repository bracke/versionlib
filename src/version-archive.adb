with Ada.Containers.Ordered_Sets;
with Ada.Directories; use Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Strings.Unbounded;

with Version.Objects; use Version.Objects;
with Version.Object_Cache;
with Version.Tree_Cache;
with Version.Files;
with Version.Revisions;
with Version.Tar;
with Version.Zip;

package body Version.Archive is

   use Ada.Strings.Unbounded;

   package String_Sets is new Ada.Containers.Ordered_Sets
     (Element_Type => Unbounded_String);

   function Unsupported_Output_Format_Text (Output : String) return String is
   begin
      return "unsupported archive output format: " & Output
        & " (supported archive outputs end in .tar or .zip; "
        & "use --format tar|zip with a matching output path)";
   end Unsupported_Output_Format_Text;

   function Is_Regular_Mode (Mode : String) return Boolean is
   begin
      return Mode = "100644";
   end Is_Regular_Mode;

   function Is_Executable_Mode (Mode : String) return Boolean is
   begin
      return Mode = "100755";
   end Is_Executable_Mode;

   function Is_Symlink_Mode (Mode : String) return Boolean is
   begin
      return Mode = "120000";
   end Is_Symlink_Mode;

   function Parent_Of (Path : String) return String is
   begin
      for I in reverse Path'Range loop
         if Path (I) = '/' then
            if I = Path'First then
               return "";
            else
               return Path (Path'First .. I - 1);
            end if;
         end if;
      end loop;
      return "";
   end Parent_Of;

   procedure Append_Parents
     (Dirs : in out String_Sets.Set;
      Path : String)
   is
      Parent : constant String := Parent_Of (Path);
   begin
      if Parent'Length = 0 then
         return;
      end if;

      Append_Parents (Dirs, Parent);
      Dirs.Include (To_Unbounded_String (Parent));
   end Append_Parents;

   function Selected
     (Path      : String;
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector)
      return Boolean
   is
   begin
      return Version.Pathspec.Matches_Any (Pathspecs, Path, False);
   end Selected;

   function Gitlink_Content
     (Id : Version.Objects.Hex_Object_Id)
      return String
   is
   begin
      return "Submodule: " & To_String (Id) & Character'Val (10);
   end Gitlink_Content;

   function Is_Disallowed_Control (C : Character) return Boolean is
   begin
      return Character'Pos (C) < 32 or else Character'Pos (C) = 127;
   end Is_Disallowed_Control;

   procedure Validate_Prefix_Component
     (Full_Prefix : String;
      Component   : String)
   is
   begin
      if Component'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with
           "empty archive prefix component in prefix: " & Full_Prefix;
      elsif Component = "." or else Component = ".." or else Component = ".git" then
         raise Ada.IO_Exceptions.Data_Error with
           "unsafe archive prefix component """ & Component & """: " & Full_Prefix;
      end if;
   end Validate_Prefix_Component;

   function Normalize_Prefix (Prefix : String) return String is
      Start : Natural;
      Stop  : Natural;
   begin
      if Prefix'Length = 0 then
         return "";
      elsif Prefix (Prefix'First) = '/' then
         raise Ada.IO_Exceptions.Data_Error with "absolute archive prefix rejected: " & Prefix;
      end if;

      for C of Prefix loop
         if C = '\' or else C = Character'Val (0) then
            raise Ada.IO_Exceptions.Data_Error with "invalid archive prefix: " & Prefix;
         elsif Is_Disallowed_Control (C) then
            raise Ada.IO_Exceptions.Data_Error with "archive prefix contains control character";
         end if;
      end loop;

      Start := Prefix'First;
      while Start <= Prefix'Last loop
         Stop := Start;
         while Stop <= Prefix'Last and then Prefix (Stop) /= '/' loop
            Stop := Stop + 1;
         end loop;

         if Stop = Start then
            if Stop /= Prefix'Last then
               raise Ada.IO_Exceptions.Data_Error with
                 "empty archive prefix component in prefix: " & Prefix;
            end if;
         else
            Validate_Prefix_Component (Prefix, Prefix (Start .. Stop - 1));
         end if;

         Start := Stop + 1;
      end loop;

      if Prefix (Prefix'Last) = '/' then
         if Prefix'Length = 1 then
            raise Ada.IO_Exceptions.Data_Error with
              "empty archive prefix component in prefix: " & Prefix;
         end if;
         return Prefix (Prefix'First .. Prefix'Last - 1);
      else
         return Prefix;
      end if;
   end Normalize_Prefix;

   function With_Prefix
     (Prefix : String;
      Path   : String)
      return String
   is
   begin
      if Prefix'Length = 0 then
         return Path;
      elsif Path'Length = 0 then
         return Prefix;
      else
         return Prefix & "/" & Path;
      end if;
   end With_Prefix;

   function Ends_With
     (Text   : String;
      Suffix : String)
      return Boolean
   is
   begin
      return Text'Length >= Suffix'Length
        and then Text (Text'Last - Suffix'Length + 1 .. Text'Last) = Suffix;
   end Ends_With;

   function Lower_ASCII (Text : String) return String is
      Result : String := Text;
   begin
      for I in Result'Range loop
         if Result (I) >= 'A' and then Result (I) <= 'Z' then
            Result (I) := Character'Val
              (Character'Pos (Result (I)) - Character'Pos ('A') + Character'Pos ('a'));
         end if;
      end loop;
      return Result;
   end Lower_ASCII;

   function Looks_Like_Unsupported_Archive_Output
     (Path : String)
      return Boolean
   is
      Lower : constant String := Lower_ASCII (Path);
   begin
      return Ends_With (Lower, ".tar.gz")
        or else Ends_With (Lower, ".tgz")
        or else Ends_With (Lower, ".gz")
        or else Ends_With (Lower, ".tar.xz")
        or else Ends_With (Lower, ".txz")
        or else Ends_With (Lower, ".xz")
        or else Ends_With (Lower, ".tar.bz2")
        or else Ends_With (Lower, ".tbz")
        or else Ends_With (Lower, ".tbz2")
        or else Ends_With (Lower, ".bz2")
        or else Ends_With (Lower, ".zipx")
        or else Ends_With (Lower, ".7z")
        or else Ends_With (Lower, ".rar");
   end Looks_Like_Unsupported_Archive_Output;

   procedure Validate_Output_Path (Output : String) is
      Normalized : constant String := Version.Files.Normalize_Separators (Output);
      Native     : constant String := Version.Files.To_Native_Path (Output);
   begin
      if Output'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with "archive output path is empty";
      end if;

      for C of Output loop
         if C = Character'Val (0) then
            raise Ada.IO_Exceptions.Data_Error with "archive output path contains NUL";
         end if;
      end loop;

      if Normalized'Length > 0
        and then Normalized (Normalized'Last) = '/'
      then
         raise Ada.IO_Exceptions.Data_Error with
           "archive output path names a directory: " & Output;
      end if;

      if Looks_Like_Unsupported_Archive_Output (Normalized) then
         raise Ada.IO_Exceptions.Data_Error with
           Unsupported_Output_Format_Text (Output);
      end if;

      if Ada.Directories.Exists (Native)
        and then Ada.Directories.Kind (Native) = Ada.Directories.Directory
      then
         raise Ada.IO_Exceptions.Data_Error with
           "archive output path names a directory: " & Output;
      end if;
   end Validate_Output_Path;

   procedure Remove_Partial_Output (Output : String) is
      Native : constant String := Version.Files.To_Native_Path (Output);
   begin
      if Output'Length > 0 and then Ada.Directories.Exists (Native)
        and then Ada.Directories.Kind (Native) = Ada.Directories.Ordinary_File
      then
         Ada.Directories.Delete_File (Native);
      end if;
   exception
      when others =>
         null;
   end Remove_Partial_Output;

   function Temp_Output_Path (Output : String) return String is
   begin
      return Output & ".version-archive-tmp";
   end Temp_Output_Path;

   procedure Create
     (Repository : Version.Repository.Repository_Handle;
      Revision   : String;
      Output     : String;
      Format     : Archive_Format := Tar_Format)
   is
      Empty : Version.Pathspec.Pathspec_Vectors.Vector;
   begin
      Create
        (Repository => Repository,
         Revision   => Revision,
         Output     => Output,
         Format     => Format,
         Pathspecs  => Empty);
   end Create;

   procedure Create
     (Repository : Version.Repository.Repository_Handle;
      Revision   : String;
      Output     : String;
      Format     : Archive_Format;
      Pathspecs  : Version.Pathspec.Pathspec_Vectors.Vector)
   is
   begin
      Create
        (Repository => Repository,
         Revision   => Revision,
         Output     => Output,
         Format     => Format,
         Pathspecs  => Pathspecs,
         Prefix     => "");
   end Create;

   procedure Create
     (Repository : Version.Repository.Repository_Handle;
      Revision   : String;
      Output     : String;
      Format     : Archive_Format;
      Pathspecs  : Version.Pathspec.Pathspec_Vectors.Vector;
      Prefix     : String)
   is
      Tree_Id : Version.Objects.Object_Id_Storage;
      Entries          : Version.Objects.Tree_Entry_Vectors.Vector;
      Selected_Entries : Version.Objects.Tree_Entry_Vectors.Vector;
      Dirs             : String_Sets.Set;
      Object_Cache : Version.Object_Cache.Object_Cache;
      Tree_Cache   : Version.Tree_Cache.Tree_Cache;
      Archive_Prefix : constant String := Normalize_Prefix (Prefix);
      Work_Output    : constant String := Temp_Output_Path (Output);
   begin
      Validate_Output_Path (Output);
      Version.Files.Require_Reasonable_Path_Length (Output);
      Version.Files.Require_Reasonable_Path_Length (Work_Output);
      Remove_Partial_Output (Work_Output);

      if Revision'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with "archive revision is empty";
      end if;

      begin
         Tree_Id := Version.Revisions.Resolve_Tree (Repository, Revision);
      exception
         when Ada.IO_Exceptions.Data_Error | Constraint_Error =>
            raise Ada.IO_Exceptions.Data_Error with "revision not found: " & Revision;
      end;

      Entries := Version.Tree_Cache.Flatten_Tree (Repository, Tree_Cache, Tree_Id);

      if Archive_Prefix'Length > 0 then
         Dirs.Include (To_Unbounded_String (Archive_Prefix));
      end if;

      if not Entries.Is_Empty then
         for I in Entries.First_Index .. Entries.Last_Index loop
            declare
               Current_Entry        : constant Version.Objects.Tree_Entry := Entries.Element (I);
               Path         : constant String := To_String (Current_Entry.Path);
               Archive_Path : constant String := With_Prefix (Archive_Prefix, Path);
            begin
               if Selected (Path, Pathspecs) then
                  Selected_Entries.Append (Current_Entry);
                  Append_Parents (Dirs, Archive_Path);
               end if;
            end;
         end loop;
      end if;

      case Format is
         when Tar_Format =>
            declare
               Writer : Version.Tar.Tar_Writer;
            begin
               Version.Tar.Create (Writer, Work_Output);

               if not Dirs.Is_Empty then
                  for Dir of Dirs loop
                     Version.Tar.Add_Directory (Writer, To_String (Dir));
                  end loop;
               end if;

               if not Selected_Entries.Is_Empty then
                  for I in Selected_Entries.First_Index .. Selected_Entries.Last_Index loop
                     declare
                        Current_Entry : constant Version.Objects.Tree_Entry := Selected_Entries.Element (I);
                        Path         : constant String := To_String (Current_Entry.Path);
                        Archive_Path : constant String := With_Prefix (Archive_Prefix, Path);
                     begin
                        if Current_Entry.Kind = Version.Objects.Tree_Gitlink then
                              Version.Tar.Add_File
                                (Writer, Archive_Path, Gitlink_Content (Current_Entry.Id), False);
                        elsif Current_Entry.Kind = Version.Objects.Tree_Blob then
                              declare
                                 Obj : constant Version.Objects.Git_Object :=
                                   Version.Object_Cache.Read_Object (Repository, Object_Cache, Current_Entry.Id);
                              begin
                                 if Version.Objects.Kind (Obj) /= Version.Objects.Blob_Object then
                                    raise Ada.IO_Exceptions.Data_Error with
                                      "archive entry is not a blob: " & Path;
                                 end if;

                                 if Is_Symlink_Mode (To_String (Current_Entry.Mode)) then
                                    Version.Tar.Add_Symlink
                                      (Writer, Archive_Path, Version.Objects.Content (Obj));
                                 elsif Is_Regular_Mode (To_String (Current_Entry.Mode))
                                   or else Is_Executable_Mode (To_String (Current_Entry.Mode))
                                 then
                                    Version.Tar.Add_File
                                      (Writer,
                                       Archive_Path,
                                       Version.Objects.Content (Obj),
                                       Is_Executable_Mode (To_String (Current_Entry.Mode)));
                                 else
                                    raise Ada.IO_Exceptions.Data_Error with
                                      "unsupported archive file mode "
                                      & To_String (Current_Entry.Mode) & ": " & Path;
                                 end if;
                              end;
                        end if;
                     end;
                  end loop;
               end if;

               Version.Tar.Close (Writer);
               Version.Files.Atomic_Replace (Work_Output, Output);
            exception
               when others =>
                  Version.Tar.Close (Writer);
                  Remove_Partial_Output (Work_Output);
                  raise;
            end;

         when Zip_Format =>
            declare
               Writer : Version.Zip.Zip_Writer;
            begin
               Version.Zip.Create (Writer, Work_Output);

               if not Dirs.Is_Empty then
                  for Dir of Dirs loop
                     Version.Zip.Add_Directory (Writer, To_String (Dir));
                  end loop;
               end if;

               if not Selected_Entries.Is_Empty then
                  for I in Selected_Entries.First_Index .. Selected_Entries.Last_Index loop
                     declare
                        Current_Entry : constant Version.Objects.Tree_Entry := Selected_Entries.Element (I);
                        Path         : constant String := To_String (Current_Entry.Path);
                        Archive_Path : constant String := With_Prefix (Archive_Prefix, Path);
                     begin
                        if Current_Entry.Kind = Version.Objects.Tree_Gitlink then
                              Version.Zip.Add_File
                                (Writer, Archive_Path, Gitlink_Content (Current_Entry.Id), False);
                        elsif Current_Entry.Kind = Version.Objects.Tree_Blob then
                              declare
                                 Obj : constant Version.Objects.Git_Object :=
                                   Version.Object_Cache.Read_Object (Repository, Object_Cache, Current_Entry.Id);
                              begin
                                 if Version.Objects.Kind (Obj) /= Version.Objects.Blob_Object then
                                    raise Ada.IO_Exceptions.Data_Error with
                                      "archive entry is not a blob: " & Path;
                                 end if;

                                 if Is_Symlink_Mode (To_String (Current_Entry.Mode)) then
                                    Version.Zip.Add_Symlink
                                      (Writer, Archive_Path, Version.Objects.Content (Obj));
                                 elsif Is_Regular_Mode (To_String (Current_Entry.Mode))
                                   or else Is_Executable_Mode (To_String (Current_Entry.Mode))
                                 then
                                    Version.Zip.Add_File
                                      (Writer,
                                       Archive_Path,
                                       Version.Objects.Content (Obj),
                                       Is_Executable_Mode (To_String (Current_Entry.Mode)));
                                 else
                                    raise Ada.IO_Exceptions.Data_Error with
                                      "unsupported archive file mode "
                                      & To_String (Current_Entry.Mode) & ": " & Path;
                                 end if;
                              end;
                        end if;
                     end;
                  end loop;
               end if;

               Version.Zip.Close (Writer);
               Version.Files.Atomic_Replace (Work_Output, Output);
            exception
               when others =>
                  Version.Zip.Close (Writer);
                  Remove_Partial_Output (Work_Output);
                  raise;
            end;
      end case;
   end Create;

end Version.Archive;
