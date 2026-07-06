with Ada.Containers;
with Ada.Directories; use Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;
with Ada.Text_IO;

with Version.Files;
with Version.Transport.Local;
with Version.Ref_Names;

use type Ada.Containers.Count_Type;

package body Version.Packed_Refs is
   use Version.Objects;

   use Ada.Strings.Unbounded;

   function Join (Left, Right : String) return String renames Version.Files.Join;

   function Packed_Refs_Path
     (Repo : Version.Repository.Repository_Handle)
      return String is
   begin
      return Join (Version.Repository.Common_Git_Dir (Repo), "packed-refs");
   end Packed_Refs_Path;

   function Is_Hex_Object_Id (Text : String) return Boolean is
   begin
      return Version.Objects.Is_Valid_Hex_Object_Id (Text);
   end Is_Hex_Object_Id;

   function Starts_With (Text, Prefix : String) return Boolean is
   begin
      return Text'Length >= Prefix'Length
        and then Text (Text'First .. Text'First + Prefix'Length - 1) = Prefix;
   end Starts_With;

   function Ends_With (Text, Suffix : String) return Boolean is
   begin
      return Text'Length >= Suffix'Length
        and then Text (Text'Last - Suffix'Length + 1 .. Text'Last) = Suffix;
   end Ends_With;

   function Is_Valid_Ref_Name (Name : String) return Boolean is
   begin
      return Version.Ref_Names.Is_Valid_Ref_Name (Name);
   end Is_Valid_Ref_Name;

   procedure Replace_Or_Append
     (Refs : in out Packed_Ref_Vectors.Vector;
      Item : Packed_Ref)
   is
      Name : constant String := To_String (Item.Name);
   begin
      if Refs.Is_Empty then
         Refs.Append (Item);
         return;
      end if;

      for I in Refs.First_Index .. Refs.Last_Index loop
         if To_String (Refs.Element (I).Name) = Name then
            Refs.Replace_Element (I, Item);
            return;
         end if;
      end loop;

      Refs.Append (Item);
   end Replace_Or_Append;

   procedure Sort_By_Name
     (Refs : in out Packed_Ref_Vectors.Vector)
   is
      Swapped : Boolean := True;
   begin
      if Refs.Length < 2 then
         return;
      end if;

      while Swapped loop
         Swapped := False;

         for I in Refs.First_Index .. Refs.Last_Index - 1 loop
            if To_String (Refs.Element (I + 1).Name)
              < To_String (Refs.Element (I).Name)
            then
               declare
                  Temp : constant Packed_Ref := Refs.Element (I);
               begin
                  Refs.Replace_Element (I,     Refs.Element (I + 1));
                  Refs.Replace_Element (I + 1, Temp);
                  Swapped := True;
               end;
            end if;
         end loop;
      end loop;
   end Sort_By_Name;

   function Normalized
     (Refs : Packed_Ref_Vectors.Vector)
      return Packed_Ref_Vectors.Vector
   is
      Result : Packed_Ref_Vectors.Vector;
   begin
      if not Refs.Is_Empty then
         for I in Refs.First_Index .. Refs.Last_Index loop
            declare
               Item : constant Packed_Ref := Refs.Element (I);
               Name : constant String := To_String (Item.Name);
            begin
               if not Is_Valid_Ref_Name (Name) then
                  raise Ada.IO_Exceptions.Data_Error with
                    "invalid packed ref name: " & Name;
               end if;

               if not Is_Hex_Object_Id (To_String (Item.Id)) then
                  raise Ada.IO_Exceptions.Data_Error with
                    "invalid packed ref object id: " & Name;
               end if;

               Replace_Or_Append (Result, Item);
            end;
         end loop;
      end if;

      Sort_By_Name (Result);
      return Result;
   end Normalized;

   function Read_All
     (Repo : Version.Repository.Repository_Handle)
      return Packed_Ref_Vectors.Vector
   is
      Path   : constant String := Packed_Refs_Path (Repo);
      File   : Ada.Text_IO.File_Type;
      Result : Packed_Ref_Vectors.Vector;
      Have_Previous_Ref : Boolean := False;
   begin
      if not Ada.Directories.Exists (Path) then
         return Result;
      end if;

      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Version.Files.To_Native_Path (Path));

      while not Ada.Text_IO.End_Of_File (File) loop
         declare
            Line : constant String := Ada.Text_IO.Get_Line (File);
         begin
            if Line'Length = 0
              or else Line (Line'First) = '#'
            then
               Have_Previous_Ref := False;

            elsif Line (Line'First) = '^' then
               if not Have_Previous_Ref
                 or else Line'Length < 2
                 or else not Is_Hex_Object_Id (Line (Line'First + 1 .. Line'Last))
               then
                  raise Ada.IO_Exceptions.Data_Error with
                    "malformed packed-ref peeled line";
               end if;

               Have_Previous_Ref := False;

            elsif Ada.Strings.Fixed.Index (Line, " ") = 0 then
               raise Ada.IO_Exceptions.Data_Error with
                 "malformed packed-ref line";

            else
               declare
                  --  "<id> <refname>": the id (40 or 64 hex) is the token
                  --  before the first space.
                  Space   : constant Natural :=
                    Ada.Strings.Fixed.Index (Line, " ");

                  Id_Text : constant String :=
                    Line (Line'First .. Space - 1);

                  Name : constant String :=
                    Line (Space + 1 .. Line'Last);
               begin
                  if not Is_Hex_Object_Id (Id_Text) then
                     raise Ada.IO_Exceptions.Data_Error with
                       "malformed packed-ref object id";
                  end if;

                  if not Is_Valid_Ref_Name (Name) then
                     raise Ada.IO_Exceptions.Data_Error with
                       "malformed packed-ref name: " & Name;
                  end if;

                  Replace_Or_Append
                    (Result,
                     (Name => To_Unbounded_String (Name),
                      Id   => Version.Objects.To_Object_Id (Id_Text)));
                  Have_Previous_Ref := True;
               end;
            end if;
         end;
      end loop;

      Ada.Text_IO.Close (File);
      Sort_By_Name (Result);
      return Result;

   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;

         raise;
   end Read_All;

   function Find
     (Repo : Version.Repository.Repository_Handle;
      Name : String;
      Id   : out Version.Objects.Hex_Object_Id)
      return Boolean
   is
      Refs : constant Packed_Ref_Vectors.Vector := Read_All (Repo);
   begin
      if Refs.Is_Empty then
         return False;
      end if;

      for I in Refs.First_Index .. Refs.Last_Index loop
         if To_String (Refs.Element (I).Name) = Name then
            Id := Refs.Element (I).Id;
            return True;
         end if;
      end loop;

      return False;
   end Find;

   procedure Write_All
     (Repo : Version.Repository.Repository_Handle;
      Refs : Packed_Ref_Vectors.Vector)
   is
      Path      : constant String := Packed_Refs_Path (Repo);
      Lock_Path : constant String := Path & ".lock";
      Sorted       : constant Packed_Ref_Vectors.Vector := Normalized (Refs);
      Lock_Created : Boolean := False;
      Content      : Unbounded_String :=
        To_Unbounded_String
          ("# pack-refs with: sorted" & Character'Val (10));
   begin
      if Ada.Directories.Exists (Lock_Path) then
         raise Ada.IO_Exceptions.Data_Error with
           "lock file already exists: " & Lock_Path;
      end if;

      if not Sorted.Is_Empty then
         for I in Sorted.First_Index .. Sorted.Last_Index loop
            Content := Content
              & To_String (Sorted.Element (I).Id)
              & " "
              & To_String (Sorted.Element (I).Name)
              & Character'Val (10);
         end loop;
      end if;

      Version.Files.Write_Binary_File
        (Path    => Lock_Path,
         Content => To_String (Content));
      Lock_Created := True;

      Version.Files.Atomic_Replace (Lock_Path, Path);
      Lock_Created := False;
   exception
      when others =>
         if Lock_Created then
            Version.Files.Delete_File_If_Exists (Lock_Path);
         end if;
         raise;
   end Write_All;

   procedure Append_Loose_Refs
     (Root_Dir   : String;
      Ref_Prefix : String;
      Result     : in out Packed_Ref_Vectors.Vector)
   is
      Search : Ada.Directories.Search_Type;
      Item   : Ada.Directories.Directory_Entry_Type;
      Opened : Boolean := False;
   begin
      if not Ada.Directories.Exists (Root_Dir) then
         return;
      end if;

      Ada.Directories.Start_Search
        (Search    => Search,
         Directory => Root_Dir,
         Pattern   => "*",
         Filter    =>
           [Ada.Directories.Ordinary_File => True,
            Ada.Directories.Directory     => True,
            Ada.Directories.Special_File  => False]);

      Opened := True;

      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Item);

         declare
            Simple : constant String := Ada.Directories.Simple_Name (Item);
            Full   : constant String := Ada.Directories.Full_Name (Item);
         begin
            if Simple = "." or else Simple = ".." then
               null;

            elsif Ada.Directories.Kind (Item) = Ada.Directories.Directory then
               Append_Loose_Refs
                 (Root_Dir   => Full,
                  Ref_Prefix => Ref_Prefix & "/" & Simple,
                  Result     => Result);

            elsif Ada.Directories.Kind (Item) = Ada.Directories.Ordinary_File
              and then not Ends_With (Simple, ".lock")
            then
               declare
                  Ref_Name : constant String := Ref_Prefix & "/" & Simple;
                  Id_Text  : constant String :=
                    Ada.Strings.Fixed.Trim
                      (Version.Transport.Local.Read_First_Line (Full),
                       Ada.Strings.Both);
               begin
                  if not Is_Valid_Ref_Name (Ref_Name) then
                     raise Ada.IO_Exceptions.Data_Error with
                       "invalid loose ref name: " & Ref_Name;
                  end if;

                  if not Is_Hex_Object_Id (Id_Text) then
                     raise Ada.IO_Exceptions.Data_Error with
                       "invalid loose ref object id: " & Ref_Name;
                  end if;

                  Replace_Or_Append
                    (Result,
                     (Name => To_Unbounded_String (Ref_Name),
                      Id   => Version.Objects.To_Object_Id (Id_Text)));
               end;
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
   end Append_Loose_Refs;

   procedure Delete_Loose_If_Packed
     (Repo : Version.Repository.Repository_Handle;
      Ref  : Packed_Ref)
   is
      Name : constant String := To_String (Ref.Name);
      Path : constant String := Join (Version.Repository.Common_Git_Dir (Repo), Name);
   begin
      if (Starts_With (Name, "refs/heads/")
          or else Starts_With (Name, "refs/tags/"))
        and then Version.Files.Is_Ordinary_File (Path)
      then
         Version.Files.Delete_File_If_Exists (Path);
      end if;
   end Delete_Loose_If_Packed;

   procedure Pack_Refs
     (Repo          : Version.Repository.Repository_Handle;
      Include_Heads : Boolean := True;
      Include_Tags  : Boolean := True;
      Prune_Loose   : Boolean := False)
   is
      Refs : Packed_Ref_Vectors.Vector := Read_All (Repo);
      Packed : Packed_Ref_Vectors.Vector;
   begin
      if Include_Heads then
         Append_Loose_Refs
           (Root_Dir   => Join (Version.Repository.Common_Git_Dir (Repo), "refs/heads"),
            Ref_Prefix => "refs/heads",
            Result     => Refs);
      end if;

      if Include_Tags then
         Append_Loose_Refs
           (Root_Dir   => Join (Version.Repository.Common_Git_Dir (Repo), "refs/tags"),
            Ref_Prefix => "refs/tags",
            Result     => Refs);
      end if;

      Packed := Normalized (Refs);
      Write_All (Repo, Packed);

      if Prune_Loose and then not Packed.Is_Empty then
         for I in Packed.First_Index .. Packed.Last_Index loop
            Delete_Loose_If_Packed (Repo, Packed.Element (I));
         end loop;
      end if;
   end Pack_Refs;

   procedure Remove
     (Repo : Version.Repository.Repository_Handle;
      Name : String)
   is
      Existing : constant Packed_Ref_Vectors.Vector := Read_All (Repo);
      Result   : Packed_Ref_Vectors.Vector;
   begin
      if not Is_Valid_Ref_Name (Name) then
         raise Ada.IO_Exceptions.Data_Error with
           "invalid packed ref name: " & Name;
      end if;

      if not Existing.Is_Empty then
         for I in Existing.First_Index .. Existing.Last_Index loop
            if To_String (Existing.Element (I).Name) /= Name then
               Result.Append (Existing.Element (I));
            end if;
         end loop;
      end if;

      Write_All (Repo, Result);
   end Remove;

end Version.Packed_Refs;
