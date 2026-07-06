with Ada.Characters.Handling;
with Ada.Containers;
with Ada.IO_Exceptions;
with Ada.Strings.Unbounded;

package body Version.Path_Safety is

   use Ada.Strings.Unbounded;
   use type Ada.Containers.Count_Type;

   function Is_Control (C : Character) return Boolean is
   begin
      return Character'Pos (C) < 32 or else Character'Pos (C) = 127;
   end Is_Control;

   function Is_Windows_Invalid_Character (C : Character) return Boolean is
   begin
      return C = '<'
        or else C = '>'
        or else C = ':'
        or else C = '"'
        or else C = '|'
        or else C = '?'
        or else C = '*';
   end Is_Windows_Invalid_Character;

   function Upper (S : String) return String is
      Result : String := S;
   begin
      for I in Result'Range loop
         Result (I) := Ada.Characters.Handling.To_Upper (Result (I));
      end loop;
      return Result;
   end Upper;

   function Device_Base (Component : String) return String is
   begin
      for I in Component'Range loop
         if Component (I) = '.' then
            if I = Component'First then
               return "";
            else
               return Component (Component'First .. I - 1);
            end if;
         end if;
      end loop;

      return Component;
   end Device_Base;

   function Is_Reserved_Windows_Device (Component : String) return Boolean is
      Base : constant String := Upper (Device_Base (Component));
   begin
      if Base = "CON"
        or else Base = "PRN"
        or else Base = "AUX"
        or else Base = "NUL"
      then
         return True;
      elsif Base'Length = 4
        and then (Base (Base'First .. Base'First + 2) = "COM"
                  or else Base (Base'First .. Base'First + 2) = "LPT")
        and then Base (Base'Last) in '1' .. '9'
      then
         return True;
      else
         return False;
      end if;
   end Is_Reserved_Windows_Device;

   procedure Validate_Common_Component
     (Path      : String;
      Component : String)
   is
   begin
      if Component'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with
           "empty path component: " & Path;
      elsif Component = "." then
         raise Ada.IO_Exceptions.Data_Error with
           "current-directory path component is not allowed: " & Path;
      elsif Component = ".." then
         raise Ada.IO_Exceptions.Data_Error with
           "path traversal is not allowed: " & Path;
      elsif Component = ".git" then
         raise Ada.IO_Exceptions.Data_Error with
           "paths inside .git are not allowed: " & Path;
      end if;
   end Validate_Common_Component;

   procedure Validate_Windows_Component
     (Path      : String;
      Component : String)
   is
   begin
      if Component (Component'Last) = ' '
        or else Component (Component'Last) = '.'
      then
         raise Ada.IO_Exceptions.Data_Error with
           "Windows path component may not end with space or dot: " & Path;
      end if;

      if Is_Reserved_Windows_Device (Component) then
         raise Ada.IO_Exceptions.Data_Error with
           "Windows reserved device name is not allowed: " & Path;
      end if;

      for C of Component loop
         if Is_Windows_Invalid_Character (C) then
            raise Ada.IO_Exceptions.Data_Error with
              "Windows-invalid character in path: " & Path;
         end if;
      end loop;
   end Validate_Windows_Component;

   function Normalize_Relative_Path
     (Path : String)
      return String
   is
      Result    : Unbounded_String;
      Component : Unbounded_String;

      procedure Finish_Component is
         Text : constant String := To_String (Component);
      begin
         Validate_Common_Component (Path, Text);
         Validate_Windows_Component (Path, Text);

         if Length (Result) > 0 then
            Append (Result, "/");
         end if;

         Append (Result, Text);
         Component := Null_Unbounded_String;
      end Finish_Component;
   begin
      if Path'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with "empty path";
      end if;

      if Path (Path'First) = '/'
        or else Path (Path'First) = '\'
        or else (Path'Length >= 2 and then Path (Path'First + 1) = ':')
      then
         raise Ada.IO_Exceptions.Data_Error with
           "absolute paths are not allowed: " & Path;
      end if;

      if Path (Path'Last) = '/' or else Path (Path'Last) = '\' then
         raise Ada.IO_Exceptions.Data_Error with
           "trailing slash is not allowed: " & Path;
      end if;

      for C of Path loop
         if C = Character'Val (0) then
            raise Ada.IO_Exceptions.Data_Error with "path contains NUL";
         elsif Is_Control (C) then
            raise Ada.IO_Exceptions.Data_Error with "path contains control character";
         elsif C = '/' or else C = '\' then
            if Length (Component) = 0 then
               raise Ada.IO_Exceptions.Data_Error with
                 "empty path component: " & Path;
            else
               Finish_Component;
            end if;
         else
            Append (Component, C);
         end if;
      end loop;

      Finish_Component;

      declare
         Normalized : constant String := To_String (Result);
      begin
         if Normalized = ".git"
           or else (Normalized'Length > 5
                    and then Normalized
                      (Normalized'First .. Normalized'First + 4) = ".git/")
         then
            raise Ada.IO_Exceptions.Data_Error with
              "paths inside .git are not allowed: " & Path;
         end if;

         return Normalized;
      end;
   end Normalize_Relative_Path;

   function Is_Safe_Relative_Path
     (Path : String)
      return Boolean
   is
      Normalized : constant String := Normalize_Relative_Path (Path);
      pragma Unreferenced (Normalized);
   begin
      return True;
   exception
      when Ada.IO_Exceptions.Data_Error =>
         return False;
   end Is_Safe_Relative_Path;

   procedure Require_Safe_Relative_Path
     (Path    : String;
      Context : String := "path")
   is
      Normalized : constant String := Normalize_Relative_Path (Path);
      pragma Unreferenced (Normalized);
   begin
      null;
   exception
      when Ada.IO_Exceptions.Data_Error =>
         raise Ada.IO_Exceptions.Data_Error with
           "unsafe " & Context & ": " & Path;
   end Require_Safe_Relative_Path;

   procedure Require_Windows_Safe_Relative_Path
     (Path    : String;
      Context : String := "path")
   is
      Result    : Unbounded_String;
      Component : Unbounded_String;

      procedure Finish_Component is
         Text : constant String := To_String (Component);
      begin
         Validate_Common_Component (Path, Text);
         Validate_Windows_Component (Path, Text);

         if Length (Result) > 0 then
            Append (Result, "/");
         end if;

         Append (Result, Text);
         Component := Null_Unbounded_String;
      end Finish_Component;
   begin
      if Path'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with "empty path";
      end if;

      if Path (Path'First) = '/'
        or else Path (Path'First) = '\'
        or else (Path'Length >= 2 and then Path (Path'First + 1) = ':')
      then
         raise Ada.IO_Exceptions.Data_Error with
           "absolute paths are not allowed: " & Path;
      end if;

      if Path (Path'Last) = '/' or else Path (Path'Last) = '\' then
         raise Ada.IO_Exceptions.Data_Error with
           "trailing slash is not allowed: " & Path;
      end if;

      for C of Path loop
         if C = Character'Val (0) then
            raise Ada.IO_Exceptions.Data_Error with "path contains NUL";
         elsif Is_Control (C) then
            raise Ada.IO_Exceptions.Data_Error with "path contains control character";
         elsif C = '/' or else C = '\' then
            if Length (Component) = 0 then
               raise Ada.IO_Exceptions.Data_Error with
                 "empty path component: " & Path;
            else
               Finish_Component;
            end if;
         else
            Append (Component, C);
         end if;
      end loop;

      Finish_Component;
   exception
      when Ada.IO_Exceptions.Data_Error =>
         raise Ada.IO_Exceptions.Data_Error with
           "unsafe " & Context & ": " & Path;
   end Require_Windows_Safe_Relative_Path;

   function Is_Windows_Safe_Relative_Path
     (Path : String)
      return Boolean
   is
   begin
      Require_Windows_Safe_Relative_Path (Path);
      return True;
   exception
      when Ada.IO_Exceptions.Data_Error =>
         return False;
   end Is_Windows_Safe_Relative_Path;

   procedure Check_Case_Collisions
     (Paths            : Path_Vector;
      Case_Insensitive : Boolean := True)
   is
   begin
      if Paths.Length < 2 then
         return;
      end if;

      for I in Paths.First_Index .. Paths.Last_Index loop
         declare
            A      : constant String := Normalize_Relative_Path (Paths.Element (I));
            Fold_A : constant String := Upper (A);
         begin
            for J in I + 1 .. Paths.Last_Index loop
               declare
                  B      : constant String := Normalize_Relative_Path (Paths.Element (J));
                  Fold_B : constant String := Upper (B);
               begin
                  if A = B then
                     raise Ada.IO_Exceptions.Data_Error with
                       "cannot checkout: duplicate path: " & A;
                  elsif Case_Insensitive and then Fold_A = Fold_B then
                     raise Ada.IO_Exceptions.Data_Error with
                       "cannot checkout: path case collision: " & A & " and " & B;
                  end if;
               end;
            end loop;
         end;
      end loop;
   end Check_Case_Collisions;

end Version.Path_Safety;
