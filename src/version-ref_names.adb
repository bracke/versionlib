with Ada.IO_Exceptions;
with Ada.Strings.Fixed;

with Version.Path_Safety;

package body Version.Ref_Names is

   function Is_Control (C : Character) return Boolean is
   begin
      return Character'Pos (C) < 32 or else Character'Pos (C) = 127;
   end Is_Control;

   function Starts_With (Value, Prefix : String) return Boolean is
   begin
      return Value'Length >= Prefix'Length
        and then Value (Value'First .. Value'First + Prefix'Length - 1) = Prefix;
   end Starts_With;

   function Ends_With (Value, Suffix : String) return Boolean is
   begin
      return Value'Length >= Suffix'Length
        and then Value (Value'Last - Suffix'Length + 1 .. Value'Last) = Suffix;
   end Ends_With;

   function Components_Are_Safe (Name : String) return Boolean is
      Start : Natural := Name'First;
   begin
      --  Branch, tag and remote-tracking refs are stored as filesystem paths
      --  under .git/refs.  Apply the Windows filename policy centrally even
      --  when running the pure helper tests on POSIX, so refs such as
      --  refs/heads/CON or refs/tags/NUL.txt cannot later become unwriteable
      --  or ambiguous on Windows.
      if not Version.Path_Safety.Is_Windows_Safe_Relative_Path (Name) then
         return False;
      end if;

      while Start <= Name'Last loop
         declare
            Stop : Natural := Start;
         begin
            while Stop <= Name'Last and then Name (Stop) /= '/' loop
               Stop := Stop + 1;
            end loop;

            if Stop = Start then
               return False;
            end if;

            declare
               Component : constant String := Name (Start .. Stop - 1);
            begin
               if Component = "." or else Component = ".." then
                  return False;
               end if;

               if Component (Component'First) = '.' then
                  return False;
               end if;

               if Ends_With (Component, ".lock") then
                  return False;
               end if;
            end;

            Start := Stop + 1;
         end;
      end loop;

      return True;
   end Components_Are_Safe;

   function Is_Valid_Check_Ref_Format
     (Name            : String;
      Allow_Onelevel  : Boolean := False;
      Refspec_Pattern : Boolean := False)
      return Boolean
   is
      Slash_Count : Natural := 0;
      Star_Count  : Natural := 0;
      Start       : Natural := Name'First;
   begin
      if Name'Length = 0 or else Name = "@" then
         return False;
      end if;
      if Name (Name'First) = '/' or else Name (Name'Last) = '/'
        or else Name (Name'Last) = '.'
      then
         return False;
      end if;
      if Ada.Strings.Fixed.Index (Name, "..") /= 0
        or else Ada.Strings.Fixed.Index (Name, "@{") /= 0
        or else Ada.Strings.Fixed.Index (Name, "//") /= 0
      then
         return False;
      end if;

      for C of Name loop
         if Is_Control (C) or else C = ' ' or else C = '~' or else C = '^'
           or else C = ':' or else C = '?' or else C = '[' or else C = '\'
         then
            return False;
         elsif C = '*' then
            Star_Count := Star_Count + 1;
         end if;
      end loop;

      --  '*' is only permitted (once) in refspec-pattern mode.
      if Star_Count > 0
        and then (not Refspec_Pattern or else Star_Count > 1)
      then
         return False;
      end if;

      --  Per-component rules: no leading '.', no ".lock" suffix, non-empty.
      while Start <= Name'Last loop
         declare
            Stop : Natural := Start;
         begin
            while Stop <= Name'Last and then Name (Stop) /= '/' loop
               Stop := Stop + 1;
            end loop;
            declare
               Comp : constant String := Name (Start .. Stop - 1);
            begin
               if Comp'Length = 0
                 or else Comp (Comp'First) = '.'
                 or else Ends_With (Comp, ".lock")
               then
                  return False;
               end if;
            end;
            if Stop <= Name'Last then
               Slash_Count := Slash_Count + 1;
            end if;
            Start := Stop + 1;
         end;
      end loop;

      return Slash_Count > 0 or else Allow_Onelevel;
   end Is_Valid_Check_Ref_Format;

   function Normalize_Ref_Format (Name : String) return String is
      Result : String (1 .. Name'Length);
      Last   : Natural := 0;
      Prev_Slash : Boolean := True;  --  drop leading slashes
   begin
      for C of Name loop
         if C = '/' then
            if not Prev_Slash then
               Last := Last + 1;
               Result (Last) := '/';
               Prev_Slash := True;
            end if;
         else
            Last := Last + 1;
            Result (Last) := C;
            Prev_Slash := False;
         end if;
      end loop;
      --  Drop any trailing slash left by collapsing.
      if Last > 0 and then Result (Last) = '/' then
         Last := Last - 1;
      end if;
      return Result (1 .. Last);
   end Normalize_Ref_Format;

   function Is_Valid_Ref_Name
     (Name : String)
      return Boolean
   is
   begin
      if Name'Length = 0
        or else Name (Name'First) = '/'
        or else Name (Name'Last) = '/'
      then
         return False;
      end if;

      if Name = "refs/stash" then
         return True;
      end if;

      if not (Starts_With (Name, "refs/heads/")
              or else Starts_With (Name, "refs/tags/")
              or else Starts_With (Name, "refs/remotes/")
              or else Starts_With (Name, "refs/notes/")
              or else Starts_With (Name, "refs/replace/")
              --  filter-branch keeps the pre-rewrite tip under refs/original/.
              or else Starts_With (Name, "refs/original/"))
      then
         return False;
      end if;

      if Ada.Strings.Fixed.Index (Name, "..") /= 0
        or else Ada.Strings.Fixed.Index (Name, "@{") /= 0
        or else Ada.Strings.Fixed.Index (Name, "//") /= 0
        or else Ends_With (Name, ".")
        or else Ends_With (Name, ".lock")
      then
         return False;
      end if;

      for C of Name loop
         if C = Character'Val (0)
           or else C = '\'
           or else Is_Control (C)
           or else C = ' '
           or else C = '~'
           or else C = '^'
           or else C = ':'
           or else C = '?'
           or else C = '*'
           or else C = '['
           or else C = '"'
         then
            return False;
         end if;
      end loop;

      return Components_Are_Safe (Name);
   end Is_Valid_Ref_Name;

   function Is_Valid_Branch_Name
     (Name : String)
      return Boolean is
   begin
      return Name'Length > 0
        and then Ada.Strings.Fixed.Index (Name, "refs/") /= 1
        and then Is_Valid_Ref_Name ("refs/heads/" & Name);
   end Is_Valid_Branch_Name;

   function Is_Valid_Tag_Name
     (Name : String)
      return Boolean is
   begin
      return Name'Length > 0
        and then Ada.Strings.Fixed.Index (Name, "refs/") /= 1
        and then Is_Valid_Ref_Name ("refs/tags/" & Name);
   end Is_Valid_Tag_Name;

   function Is_Valid_Remote_Name
     (Name : String)
      return Boolean
   is
   begin
      if Name'Length = 0
        or else Ada.Strings.Fixed.Index (Name, "..") /= 0
        or else Ada.Strings.Fixed.Index (Name, "//") /= 0
        or else Name (Name'First) = '/'
        or else Name (Name'Last) = '/'
        or else Ends_With (Name, ".lock")
      then
         return False;
      end if;

      for C of Name loop
         case C is
            when 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' | '.' =>
               null;
            when others =>
               return False;
         end case;
      end loop;

      return Components_Are_Safe (Name);
   end Is_Valid_Remote_Name;

   procedure Require_Ref_Name (Name : String) is
   begin
      if not Is_Valid_Ref_Name (Name) then
         raise Ada.IO_Exceptions.Data_Error with "invalid ref name: " & Name;
      end if;
   end Require_Ref_Name;

   procedure Require_Branch_Name (Name : String) is
   begin
      if not Is_Valid_Branch_Name (Name) then
         raise Ada.IO_Exceptions.Data_Error with "invalid branch name: " & Name;
      end if;
   end Require_Branch_Name;

   procedure Require_Tag_Name (Name : String) is
   begin
      if not Is_Valid_Tag_Name (Name) then
         raise Ada.IO_Exceptions.Data_Error with "invalid tag name: " & Name;
      end if;
   end Require_Tag_Name;

   procedure Require_Remote_Name (Name : String) is
   begin
      if not Is_Valid_Remote_Name (Name) then
         raise Ada.IO_Exceptions.Data_Error with "invalid remote name: " & Name;
      end if;
   end Require_Remote_Name;

end Version.Ref_Names;
