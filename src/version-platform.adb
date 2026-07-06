with Ada.Characters.Handling;
with Ada.Environment_Variables;

package body Version.Platform is

   function Lower (Value : String) return String is
      Result : String := Value;
   begin
      for I in Result'Range loop
         Result (I) := Ada.Characters.Handling.To_Lower (Result (I));
      end loop;
      return Result;
   end Lower;

   function Contains
     (Text    : String;
      Pattern : String)
      return Boolean
   is
   begin
      if Pattern'Length = 0 then
         return True;
      elsif Text'Length < Pattern'Length then
         return False;
      end if;

      for I in Text'First .. Text'Last - Pattern'Length + 1 loop
         if Text (I .. I + Pattern'Length - 1) = Pattern then
            return True;
         end if;
      end loop;

      return False;
   end Contains;

   function Looks_Like_Windows return Boolean is
   begin
      return
        (Ada.Environment_Variables.Exists ("OS")
         and then Lower (Ada.Environment_Variables.Value ("OS")) = "windows_nt")
        or else Ada.Environment_Variables.Exists ("COMSPEC");
   exception
      when others =>
         return False;
   end Looks_Like_Windows;

   function Looks_Like_Darwin return Boolean is
   begin
      if Ada.Environment_Variables.Exists ("OSTYPE") then
         declare
            Value : constant String :=
              Lower (Ada.Environment_Variables.Value ("OSTYPE"));
         begin
            return Contains (Value, "darwin") or else Contains (Value, "apple");
         end;
      elsif Ada.Environment_Variables.Exists ("MACHTYPE") then
         declare
            Value : constant String :=
              Lower (Ada.Environment_Variables.Value ("MACHTYPE"));
         begin
            return Contains (Value, "darwin") or else Contains (Value, "apple");
         end;
      else
         return False;
      end if;
   exception
      when others =>
         return False;
   end Looks_Like_Darwin;

   function Current return Platform_Kind is
   begin
      if Looks_Like_Windows then
         return Windows_Platform;
      else
         return POSIX_Platform;
      end if;
   exception
      when others =>
         return Unknown_Platform;
   end Current;

   function Is_Case_Insensitive_Default return Boolean is
   begin
      return Current = Windows_Platform or else Looks_Like_Darwin;
   end Is_Case_Insensitive_Default;

   function Supports_Executable_Bit return Boolean is
   begin
      return Current = POSIX_Platform;
   end Supports_Executable_Bit;

   function Core_Filemode_Default return String is
   begin
      if Supports_Executable_Bit then
         return "true";
      else
         return "false";
      end if;
   end Core_Filemode_Default;

   function Is_Windows_Drive_Path
     (Path : String)
      return Boolean
   is
      use Ada.Characters.Handling;
   begin
      return Path'Length >= 3
        and then Is_Letter (Path (Path'First))
        and then Path (Path'First + 1) = ':'
        and then (Path (Path'First + 2) = '/'
                  or else Path (Path'First + 2) = '\');
   end Is_Windows_Drive_Path;

   function Is_Windows_Drive_Like_Path
     (Path : String)
      return Boolean
   is
      use Ada.Characters.Handling;
   begin
      return Is_Windows_Drive_Path (Path)
        or else (Path'Length >= 2
                 and then Is_Letter (Path (Path'First))
                 and then Path (Path'First + 1) = ':');
   end Is_Windows_Drive_Like_Path;

   function Native_Path_Separator return Character is
   begin
      if Current = Windows_Platform then
         return '\';
      else
         return '/';
      end if;
   end Native_Path_Separator;

end Version.Platform;
