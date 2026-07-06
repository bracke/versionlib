with Ada.Directories; use Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Strings;
with Ada.Strings.Fixed;
with Ada.Text_IO;

with GNAT.OS_Lib;

with Version.Platform;

with Version.Files;

package body Version.Transport.Local is

   use Ada.Strings.Unbounded;

   type Object_Copy is record
      Source : Unbounded_String;
      Target : Unbounded_String;
   end record;

   package Object_Copy_Vectors is new
     Ada.Containers.Vectors
       (Index_Type   => Natural,
        Element_Type => Object_Copy);

   function Contains_Control (Value : String) return Boolean is
   begin
      for C of Value loop
         if Character'Pos (C) < 32 or else Character'Pos (C) = 127 then
            return True;
         end if;
      end loop;

      return False;
   end Contains_Control;

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

   function Resolve_Gitdir_Target
     (Root : String;
      Text : String)
      return String
   is
      Value : constant String :=
        Ada.Strings.Fixed.Trim (Text, Ada.Strings.Both);
      Normal_Value : constant String :=
        Version.Files.Normalize_Separators (Value);
   begin
      if Value'Length = 0
        or else Contains_Control (Value)
        or else Ada.Strings.Fixed.Index (Normal_Value, "//") /= 0
        or else Contains_Dot_Path_Component (Normal_Value)
      then
         raise Ada.IO_Exceptions.Data_Error with
           "invalid remote .git gitdir file: " & Root;
      end if;

      if Normal_Value (Normal_Value'First) = '/'
        or else Version.Platform.Is_Windows_Drive_Path (Normal_Value)
      then
         return Normal_Value;
      end if;

      return Version.Files.Normalize_Separators
        (Ada.Directories.Full_Name
           (Version.Files.To_Native_Path
              (Version.Files.Join (Root, Normal_Value))));
   end Resolve_Gitdir_Target;

   function Resolve_Git_File
     (Root : String;
      Path : String)
      return String
   is
      Prefix : constant String := "gitdir:";
      Line   : constant String := Read_First_Line (Path);
   begin
      if Line'Length < Prefix'Length
        or else Line (Line'First .. Line'First + Prefix'Length - 1) /= Prefix
      then
         raise Ada.IO_Exceptions.Data_Error with
           "remote .git file does not contain gitdir: " & Root;
      end if;

      declare
         Resolved : constant String :=
           Resolve_Gitdir_Target
             (Root => Root,
              Text => Line (Line'First + Prefix'Length .. Line'Last));
      begin
         if not Ada.Directories.Exists (Version.Files.To_Native_Path (Resolved))
           or else Ada.Directories.Kind (Version.Files.To_Native_Path (Resolved))
             /= Ada.Directories.Directory
         then
            raise Ada.IO_Exceptions.Data_Error with
              "remote gitdir target does not exist: " & Resolved;
         end if;

         return Resolved;
      end;
   end Resolve_Git_File;

   function Resolve_Git_Dir
     (Url : String)
      return String
   is
      Root : constant String := Version.Files.Normalize_Separators (Url);
      Dot_Git : constant String :=
        Version.Files.Join (Root, ".git");

      Objects : constant String :=
        Version.Files.Join (Root, "objects");
   begin
      if Ada.Directories.Exists (Version.Files.To_Native_Path (Dot_Git)) then
         case Ada.Directories.Kind (Version.Files.To_Native_Path (Dot_Git)) is
            when Ada.Directories.Directory =>
               return Dot_Git;

            when Ada.Directories.Ordinary_File =>
               return Resolve_Git_File (Root, Dot_Git);

            when others =>
               raise Ada.IO_Exceptions.Data_Error with
                 "remote .git is neither directory nor file: " & Root;
         end case;
      end if;

      if Ada.Directories.Exists (Version.Files.To_Native_Path (Objects))
        and then Ada.Directories.Kind (Version.Files.To_Native_Path (Objects))
          = Ada.Directories.Directory
      then
         return Root;
      end if;

      raise Ada.IO_Exceptions.Data_Error with
        "remote is not a local Git repository: " & Url;
   end Resolve_Git_Dir;

   function Read_First_Line
     (Path : String)
      return String
   is
      File : Ada.Text_IO.File_Type;
   begin
      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Version.Files.To_Native_Path (Path));

      declare
         Line : constant String :=
           Ada.Text_IO.Get_Line (File);
      begin
         Ada.Text_IO.Close (File);

         return
           Ada.Strings.Fixed.Trim
             (Line,
              Ada.Strings.Both);
      end;

   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;

         raise;
   end Read_First_Line;

   procedure Validate_File_Copy
     (Source : String;
      Target : String)
   is
      Source_Content : constant String := Version.Files.Read_Binary_File (Source);
   begin
      if Ada.Directories.Exists (Target) then
         if Version.Files.Read_Binary_File (Target) /= Source_Content then
            raise Ada.IO_Exceptions.Data_Error with
              "local object collision while copying object store: " & Target;
         end if;
      end if;
   end Validate_File_Copy;

   procedure Copy_File_If_Missing
     (Source         : String;
      Target         : String;
      Copied_Targets : in out Copied_Object_Vectors.Vector)
   is
   begin
      if Ada.Directories.Exists (Target) then
         return;
      end if;

      Version.Files.Write_Binary_File
        (Path    => Target,
         Content => Version.Files.Read_Binary_File (Source));
      Copied_Targets.Append
        (Copied_Object'(Target => To_Unbounded_String (Target)));
   end Copy_File_If_Missing;

   function Is_Hex_Name
     (Name            : String;
      Expected_Length : Natural)
      return Boolean
   is
   begin
      if Name'Length /= Expected_Length then
         return False;
      end if;

      for C of Name loop
         if C not in '0' .. '9'
           and then C not in 'a' .. 'f'
           and then C not in 'A' .. 'F'
         then
            return False;
         end if;
      end loop;

      return True;
   end Is_Hex_Name;

   function Has_Suffix (Value : String; Suffix : String) return Boolean is
   begin
      return Value'Length >= Suffix'Length
        and then Value (Value'Last - Suffix'Length + 1 .. Value'Last)
          = Suffix;
   end Has_Suffix;

   function Is_Pack_Metadata_File (Name : String) return Boolean is
   begin
      return Has_Suffix (Name, ".pack")
        or else Has_Suffix (Name, ".idx")
        or else Has_Suffix (Name, ".promisor")
        or else Has_Suffix (Name, ".bitmap")
        or else Has_Suffix (Name, ".rev")
        or else Name = "multi-pack-index";
   end Is_Pack_Metadata_File;

   function Is_Info_Metadata_File (Name : String) return Boolean is
   begin
      return Name = "packs"
        or else Name = "commit-graph";
   end Is_Info_Metadata_File;

   procedure Reject_Invalid_Object_Store_Entry (Path : String) is
   begin
      raise Ada.IO_Exceptions.Data_Error with
        "invalid local object-store entry: " & Path;
   end Reject_Invalid_Object_Store_Entry;

   procedure Collect_Directory_Tree
     (Source_Dir   : String;
      Target_Dir   : String;
      Relative_Dir : String;
      Copies       : in out Object_Copy_Vectors.Vector)
   is
      Search   : Ada.Directories.Search_Type;
      Dir_Item : Ada.Directories.Directory_Entry_Type;
      Opened   : Boolean := False;
   begin
      if not Ada.Directories.Exists (Source_Dir) then
         return;
      end if;

      Ada.Directories.Start_Search
        (Search    => Search,
         Directory => Source_Dir,
         Pattern   => "*",
         Filter    =>
           [Ada.Directories.Ordinary_File => True,
            Ada.Directories.Directory     => True,
            Ada.Directories.Special_File  => True]);

      Opened := True;

      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Dir_Item);

         declare
            Name : constant String := Ada.Directories.Simple_Name (Dir_Item);
            Source_Path : constant String := Ada.Directories.Full_Name (Dir_Item);
            Target_Path : constant String := Version.Files.Join (Target_Dir, Name);
            Child_Relative : constant String :=
              (if Relative_Dir'Length = 0 then Name else Relative_Dir & "/" & Name);
         begin
            if Name = "." or else Name = ".." then
               null;

            elsif GNAT.OS_Lib.Is_Symbolic_Link
                    (Version.Files.To_Native_Path (Source_Path))
            then
               Reject_Invalid_Object_Store_Entry (Source_Path);

            elsif Ada.Directories.Kind (Dir_Item) = Ada.Directories.Special_File then
               Reject_Invalid_Object_Store_Entry (Source_Path);

            elsif Ada.Directories.Kind (Dir_Item) = Ada.Directories.Directory then
               if Relative_Dir'Length = 0 then
                  if Name = "pack" or else Name = "info" or else Is_Hex_Name (Name, 2) then
                     Collect_Directory_Tree
                       (Source_Dir   => Source_Path,
                        Target_Dir   => Target_Path,
                        Relative_Dir => Child_Relative,
                        Copies       => Copies);
                  else
                     Reject_Invalid_Object_Store_Entry (Source_Path);
                  end if;

               elsif Relative_Dir = "pack" or else Relative_Dir = "info" then
                  Reject_Invalid_Object_Store_Entry (Source_Path);

               else
                  Reject_Invalid_Object_Store_Entry (Source_Path);
               end if;

            else
               if (Relative_Dir = "pack" and then Is_Pack_Metadata_File (Name))
                 or else (Relative_Dir = "info" and then Is_Info_Metadata_File (Name))
               then
                  Validate_File_Copy (Source => Source_Path, Target => Target_Path);
                  Copies.Append
                    (Object_Copy'
                       (Source => To_Unbounded_String (Source_Path),
                        Target => To_Unbounded_String (Target_Path)));
               elsif Is_Hex_Name (Relative_Dir, 2)
                 and then (Is_Hex_Name (Name, 38)   --  sha1 loose object
                           or else Is_Hex_Name (Name, 62))  --  sha256
               then
                  Validate_File_Copy (Source => Source_Path, Target => Target_Path);
                  Copies.Append
                    (Object_Copy'
                       (Source => To_Unbounded_String (Source_Path),
                        Target => To_Unbounded_String (Target_Path)));
               else
                  Reject_Invalid_Object_Store_Entry (Source_Path);
               end if;
            end if;
         end;
      end loop;

      Ada.Directories.End_Search (Search);

   exception
      when others =>
         if Opened then
            Ada.Directories.End_Search (Search);
         end if;

         raise;
   end Collect_Directory_Tree;

   procedure Rollback_Copied_Objects
     (Copied_Targets : Copied_Object_Vectors.Vector)
   is
   begin
      if not Copied_Targets.Is_Empty then
         for I in reverse Copied_Targets.First_Index .. Copied_Targets.Last_Index loop
            Version.Files.Delete_File_If_Exists
              (To_String (Copied_Targets.Element (I).Target));
         end loop;
      end if;
   end Rollback_Copied_Objects;

   procedure Copy_Object_Store
     (Source_Git_Dir : String;
      Target_Git_Dir : String)
   is
      Copied_Targets : Copied_Object_Vectors.Vector;
   begin
      Copy_Object_Store
        (Source_Git_Dir => Source_Git_Dir,
         Target_Git_Dir => Target_Git_Dir,
         Copied_Targets => Copied_Targets);
   end Copy_Object_Store;

   procedure Copy_Object_Store
     (Source_Git_Dir : String;
      Target_Git_Dir : String;
      Copied_Targets : out Copied_Object_Vectors.Vector)
   is
      Copies : Object_Copy_Vectors.Vector;
   begin
      Copied_Targets.Clear;
      Collect_Directory_Tree
        (Source_Dir   => Version.Files.Join (Source_Git_Dir, "objects"),
         Target_Dir   => Version.Files.Join (Target_Git_Dir, "objects"),
         Relative_Dir => "",
         Copies       => Copies);

      if not Copies.Is_Empty then
         for I in Copies.First_Index .. Copies.Last_Index loop
            declare
               Item : constant Object_Copy := Copies.Element (I);
            begin
               Copy_File_If_Missing
                 (Source         => To_String (Item.Source),
                  Target         => To_String (Item.Target),
                  Copied_Targets => Copied_Targets);
            end;
         end loop;
      end if;
   exception
      when others =>
         Rollback_Copied_Objects (Copied_Targets);
         raise;
   end Copy_Object_Store;

end Version.Transport.Local;