with Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;

with Version.Files;
with Version.Path_Safety;

package body Version.Gitmodules is

   function Trim (Text : String) return String is
      First : Natural := Text'First;
      Last  : Natural := Text'Last;
   begin
      while First <= Last
        and then (Text (First) = ' '
                  or else Text (First) = Character'Val (9)
                  or else Text (First) = Character'Val (13))
      loop
         First := First + 1;
      end loop;

      while Last >= First
        and then (Text (Last) = ' '
                  or else Text (Last) = Character'Val (9)
                  or else Text (Last) = Character'Val (13))
      loop
         Last := Last - 1;
      end loop;

      if First > Last then
         return "";
      end if;

      return Text (First .. Last);
   end Trim;

   function Strip_Quotes (Text : String) return String is
   begin
      if Text'Length >= 2
        and then Text (Text'First) = '"'
        and then Text (Text'Last) = '"'
      then
         return Text (Text'First + 1 .. Text'Last - 1);
      end if;
      return Text;
   end Strip_Quotes;

   procedure Require_Config_Value
     (Value   : String;
      Context : String)
   is
   begin
      if Value'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with
           "empty submodule " & Context;
      end if;

      for C of Value loop
         if Character'Pos (C) < 32 or else Character'Pos (C) = 127 then
            raise Ada.IO_Exceptions.Data_Error with
              "invalid control character in submodule " & Context;
         end if;
      end loop;
   end Require_Config_Value;

   procedure Require_Config_Name (Name : String) is
   begin
      Require_Config_Value (Name, "name");

      if Name (Name'First) = ' ' or else Name (Name'Last) = ' ' then
         raise Ada.IO_Exceptions.Data_Error with
           "submodule name has leading/trailing space";
      end if;

      for C of Name loop
         if C = '"' or else Character'Pos (C) < 32 then
            raise Ada.IO_Exceptions.Data_Error with
              "invalid character in submodule name";
         end if;
      end loop;
   end Require_Config_Name;

   function Config_Path (Repository_Path : String) return String is
   begin
      return Version.Files.Join (Repository_Path, ".gitmodules");
   end Config_Path;

   procedure Require_No_Duplicate_Path
     (Items : Submodule_Config_Vectors.Vector;
      Path  : String)
   is
   begin
      if not Items.Is_Empty then
         for I in Items.First_Index .. Items.Last_Index loop
            if To_String (Items.Element (I).Path) = Path then
               raise Ada.IO_Exceptions.Data_Error with
                 "duplicate submodule path: " & Path;
            end if;
         end loop;
      end if;
   end Require_No_Duplicate_Path;

   function Read
     (Repository_Path : String)
      return Submodule_Config_Vectors.Vector
   is
      Path : constant String := Config_Path (Repository_Path);
      Result : Submodule_Config_Vectors.Vector;
      Current : Submodule_Config;
      In_Section : Boolean := False;
      Current_Has_Path : Boolean := False;
      Current_Has_Url  : Boolean := False;

      procedure Finish_Section is
         Sub_Path : constant String := To_String (Current.Path);
      begin
         if not In_Section then
            return;
         end if;

         if Length (Current.Name) = 0 then
            raise Ada.IO_Exceptions.Data_Error with "submodule missing name";
         end if;

         if not Current_Has_Path or else Length (Current.Path) = 0 then
            raise Ada.IO_Exceptions.Data_Error with
              "submodule missing path: " & To_String (Current.Name);
         end if;

         if not Current_Has_Url or else Length (Current.Url) = 0 then
            raise Ada.IO_Exceptions.Data_Error with
              "submodule missing url: " & To_String (Current.Name);
         end if;

         Require_Config_Name (To_String (Current.Name));
         Require_Config_Value (Sub_Path, "path");
         Require_Config_Value (To_String (Current.Url), "url");

         declare
            Normalized_Sub_Path : constant String :=
              Version.Path_Safety.Normalize_Relative_Path (Sub_Path);
         begin
            Current.Path := To_Unbounded_String (Normalized_Sub_Path);
            Require_No_Duplicate_Path (Result, Normalized_Sub_Path);
            Result.Append (Current);
         end;
      end Finish_Section;

   begin
      if not Ada.Directories.Exists (Version.Files.To_Native_Path (Path)) then
         return Result;
      end if;

      declare
         Data : constant String := Version.Files.Read_Binary_File (Path);
         First : Natural := Data'First;
      begin
         while First <= Data'Last loop
            declare
               Last : Natural := First;
            begin
               while Last <= Data'Last and then Data (Last) /= Character'Val (10) loop
                  Last := Last + 1;
               end loop;

               declare
                  Raw_Line : constant String :=
                    (if Last > First then Data (First .. Last - 1) else "");
                  Line : constant String := Trim (Raw_Line);
               begin
                  if Line'Length = 0
                    or else Line (Line'First) = '#'
                    or else Line (Line'First) = ';'
                  then
                     null;
                  elsif Line'Length >= 13
                    and then Line (Line'First .. Line'First + 10) = "[submodule "
                    and then Line (Line'Last) = ']'
                  then
                     Finish_Section;
                     Current :=
                       (Name => To_Unbounded_String
                                  (Strip_Quotes
                                     (Trim
                                        (Line (Line'First + 11 .. Line'Last - 1)))),
                        Path => Null_Unbounded_String,
                        Url  => Null_Unbounded_String);
                     Current_Has_Path := False;
                     Current_Has_Url  := False;
                     In_Section := True;
                  else
                     if not In_Section then
                        raise Ada.IO_Exceptions.Data_Error with
                          "malformed .gitmodules entry outside submodule section";
                     end if;

                     declare
                        Eq : constant Natural := Ada.Strings.Fixed.Index (Line, "=");
                     begin
                        if Eq = 0 then
                           raise Ada.IO_Exceptions.Data_Error with
                             "malformed .gitmodules line";
                        end if;

                        declare
                           Key : constant String := Trim (Line (Line'First .. Eq - 1));
                           Value : constant String := Trim (Line (Eq + 1 .. Line'Last));
                        begin
                           if Key = "path" then
                              if Current_Has_Path then
                                 raise Ada.IO_Exceptions.Data_Error with
                                   "duplicate submodule path key";
                              end if;
                              Current.Path := To_Unbounded_String (Value);
                              Current_Has_Path := True;
                           elsif Key = "url" then
                              if Current_Has_Url then
                                 raise Ada.IO_Exceptions.Data_Error with
                                   "duplicate submodule url key";
                              end if;
                              Current.Url := To_Unbounded_String (Value);
                              Current_Has_Url := True;
                           else
                              null;
                           end if;
                        end;
                     end;
                  end if;
               end;

               First := Last + 1;
            end;
         end loop;
      end;

      Finish_Section;
      return Result;
   end Read;

   function Read
     (Repo : Version.Repository.Repository_Handle)
      return Submodule_Config_Vectors.Vector is
   begin
      return Read (Version.Repository.Root_Path (Repo));
   end Read;

   procedure Write
     (Repository_Path : String;
      Items           : Submodule_Config_Vectors.Vector)
   is
      Text : Unbounded_String;
   begin
      --  Validate duplicates with a simple prefix pass compatible with Ada 2022.
      if not Items.Is_Empty then
         for I in Items.First_Index .. Items.Last_Index loop
            declare
               Item : constant Submodule_Config := Items.Element (I);
               Sub_Path : constant String := To_String (Item.Path);
               Normalized_Sub_Path : constant String :=
                 Version.Path_Safety.Normalize_Relative_Path (Sub_Path);
            begin
               Require_Config_Name (To_String (Item.Name));
               Require_Config_Value (Normalized_Sub_Path, "path");
               Require_Config_Value (To_String (Item.Url), "url");

               if I > Items.First_Index then
                  for J in Items.First_Index .. I - 1 loop
                     if Version.Path_Safety.Normalize_Relative_Path
                       (To_String (Items.Element (J).Path)) = Normalized_Sub_Path
                     then
                        raise Ada.IO_Exceptions.Data_Error with
                          "duplicate submodule path: " & Normalized_Sub_Path;
                     end if;
                  end loop;
               end if;

               Append (Text, "[submodule """);
               Append (Text, To_String (Item.Name));
               Append (Text, """]" & Character'Val (10));
               Append (Text, Character'Val (9) & "path = ");
               Append (Text, Normalized_Sub_Path & Character'Val (10));
               Append (Text, Character'Val (9) & "url = ");
               Append (Text, To_String (Item.Url) & Character'Val (10));
            end;
         end loop;
      end if;

      Version.Files.Write_Binary_File_Atomic
        (Path    => Config_Path (Repository_Path),
         Content => To_String (Text));
   end Write;

   procedure Write
     (Repo  : Version.Repository.Repository_Handle;
      Items : Submodule_Config_Vectors.Vector) is
   begin
      Write (Version.Repository.Root_Path (Repo), Items);
   end Write;

   function Find_By_Path
     (Items : Submodule_Config_Vectors.Vector;
      Path  : String)
      return Natural
   is
      Normalized_Path : constant String :=
        Version.Path_Safety.Normalize_Relative_Path (Path);
   begin
      if not Items.Is_Empty then
         for I in Items.First_Index .. Items.Last_Index loop
            if To_String (Items.Element (I).Path) = Normalized_Path then
               return I;
            end if;
         end loop;
      end if;

      return Natural'Last;
   end Find_By_Path;

end Version.Gitmodules;
