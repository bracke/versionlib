with Ada.Containers.Ordered_Sets;
with Ada.IO_Exceptions;
with Ada.Strings.Unbounded;

with Version.Files;

package body Version.Shallow is
   use Version.Objects;

   use Ada.Strings.Unbounded;

   LF : constant Character := Character'Val (10);

   package Object_Id_Sets is new Ada.Containers.Ordered_Sets
     (Element_Type => Version.Objects.Object_Id_Storage);

   function Path
     (Repo : Version.Repository.Repository_Handle)
      return String
   is
   begin
      return Version.Files.Join (Version.Repository.Common_Git_Dir (Repo), "shallow");
   end Path;

   function Temp_Path
     (Repo : Version.Repository.Repository_Handle)
      return String
   is
   begin
      return Path (Repo) & ".lock";
   end Temp_Path;

   function Contains
     (Items : Version.Objects.Object_Id_Vectors.Vector;
      Id    : Version.Objects.Hex_Object_Id)
      return Boolean
   is
   begin
      if Items.Is_Empty then
         return False;
      end if;

      for I in Items.First_Index .. Items.Last_Index loop
         if Items.Element (I) = Id then
            return True;
         end if;
      end loop;

      return False;
   end Contains;

   procedure Append_Unique
     (Items : in out Version.Objects.Object_Id_Vectors.Vector;
      Id    : Version.Objects.Hex_Object_Id)
   is
   begin
      if not Contains (Items, Id) then
         Items.Append (Id);
      end if;
   end Append_Unique;

   function Less_Object_Id
     (Left  : Version.Objects.Hex_Object_Id;
      Right : Version.Objects.Hex_Object_Id)
      return Boolean
   is
   begin
      return To_String (Left) < To_String (Right);
   end Less_Object_Id;

   procedure Sort
     (Items : in out Version.Objects.Object_Id_Vectors.Vector)
   is
      package Object_Id_Sorting is
        new Version.Objects.Object_Id_Vectors.Generic_Sorting
          ("<" => Less_Object_Id);
   begin
      if Natural (Items.Length) < 2 then
         return;
      end if;

      Object_Id_Sorting.Sort (Items);
   end Sort;

   function Normalized
     (Items : Version.Objects.Object_Id_Vectors.Vector)
      return Version.Objects.Object_Id_Vectors.Vector
   is
      Result : Version.Objects.Object_Id_Vectors.Vector;
      Seen   : Object_Id_Sets.Set;
   begin
      if not Items.Is_Empty then
         for I in Items.First_Index .. Items.Last_Index loop
            if not Version.Objects.Is_Valid_Hex_Object_Id (To_String (Items.Element (I))) then
               raise Ada.IO_Exceptions.Data_Error with "invalid shallow object id";
            end if;

            if not Seen.Contains (Items.Element (I)) then
               Seen.Include (Items.Element (I));
               Result.Append (Items.Element (I));
            end if;
         end loop;
      end if;

      Sort (Result);
      return Result;
   end Normalized;

   function Exists
     (Repo : Version.Repository.Repository_Handle)
      return Boolean
   is
   begin
      return Version.Files.Is_Ordinary_File (Path (Repo));
   end Exists;

   function Read
     (Repo : Version.Repository.Repository_Handle)
      return Version.Objects.Object_Id_Vectors.Vector
   is
      Result    : Version.Objects.Object_Id_Vectors.Vector;
      Seen      : Object_Id_Sets.Set;
      File_Path : constant String := Path (Repo);
   begin
      if not Version.Files.Is_Ordinary_File (File_Path) then
         return Result;
      end if;

      declare
         Content : constant String := Version.Files.Read_Binary_File (File_Path);
         Start   : Natural := Content'First;
      begin
         if Content'Length = 0 then
            return Result;
         end if;

         while Start <= Content'Last loop
            declare
               Stop : Natural := Start;
            begin
               while Stop <= Content'Last and then Content (Stop) /= LF loop
                  Stop := Stop + 1;
               end loop;

               if Stop = Start then
                  raise Ada.IO_Exceptions.Data_Error with "empty shallow line";
               end if;

               declare
                  Line : constant String := Content (Start .. Stop - 1);
               begin
                  if not Version.Objects.Is_Valid_Hex_Object_Id (Line) then
                     raise Ada.IO_Exceptions.Data_Error with "malformed shallow object id";
                  end if;
                  declare
                     Id : constant Version.Objects.Hex_Object_Id :=
                       Version.Objects.To_Object_Id (Line);
                  begin
                     if not Seen.Contains (Id) then
                        Seen.Include (Id);
                        Result.Append (Id);
                     end if;
                  end;
               end;

               Start := Stop + 1;
            end;
         end loop;
      end;

      Sort (Result);
      return Result;
   end Read;

   procedure Write
     (Repo  : Version.Repository.Repository_Handle;
      Items : Version.Objects.Object_Id_Vectors.Vector)
   is
      Clean : constant Version.Objects.Object_Id_Vectors.Vector := Normalized (Items);
      File_Path : constant String := Path (Repo);
      Lock_Path : constant String := Temp_Path (Repo);
      Content   : Unbounded_String;
   begin
      if Clean.Is_Empty then
         Version.Files.Delete_File_If_Exists (Lock_Path);
         Version.Files.Delete_File_If_Exists (File_Path);
         return;
      end if;

      for I in Clean.First_Index .. Clean.Last_Index loop
         Content := Content & To_String (Clean.Element (I)) & LF;
      end loop;

      Version.Files.Write_Binary_File (Lock_Path, To_String (Content));
      Version.Files.Atomic_Replace (Lock_Path, File_Path);
   end Write;

   procedure Add
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id)
   is
      Items : Version.Objects.Object_Id_Vectors.Vector := Read (Repo);
   begin
      Append_Unique (Items, Commit_Id);
      Write (Repo, Items);
   end Add;

   procedure Remove
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id)
   is
      Items  : constant Version.Objects.Object_Id_Vectors.Vector := Read (Repo);
      Result : Version.Objects.Object_Id_Vectors.Vector;
   begin
      if not Items.Is_Empty then
         for I in Items.First_Index .. Items.Last_Index loop
            if Items.Element (I) /= Commit_Id then
               Result.Append (Items.Element (I));
            end if;
         end loop;
      end if;
      Write (Repo, Result);
   end Remove;

   function Is_Shallow_Boundary
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id)
      return Boolean
   is
   begin
      return Contains (Read (Repo), Commit_Id);
   end Is_Shallow_Boundary;

   procedure Validate_Depth (Depth : Natural) is
   begin
      if Depth = 0 then
         raise Ada.IO_Exceptions.Data_Error with "depth must be a positive integer";
      end if;
   end Validate_Depth;

end Version.Shallow;
