with Ada.IO_Exceptions;
with Ada.Strings.Fixed;
with Version.Platform;

package body Version.Transport is

   function Starts_With
     (Value  : String;
      Prefix : String)
      return Boolean
   is
   begin
      return Value'Length >= Prefix'Length
        and then Value
          (Value'First .. Value'First + Prefix'Length - 1) = Prefix;
   end Starts_With;

   function Contains_Control (Value : String) return Boolean is
   begin
      for C of Value loop
         if C = Character'Val (0)
           or else Character'Pos (C) < 32
           or else Character'Pos (C) = 127
         then
            return True;
         end if;
      end loop;

      return False;
   end Contains_Control;

   function Has_Scheme (Url : String) return Boolean is
      Pos : constant Natural := Ada.Strings.Fixed.Index (Url, "://");
   begin
      return Pos /= 0;
   end Has_Scheme;

   function Is_Scp_Like_Ssh (Url : String) return Boolean is
      Colon : constant Natural := Ada.Strings.Fixed.Index (Url, ":");
      Slash : constant Natural := Ada.Strings.Fixed.Index (Url, "/");
   begin
      if Colon = 0 or else Colon = Url'First or else Colon = Url'Last then
         return False;
      end if;

      if Version.Platform.Is_Windows_Drive_Like_Path (Url) then
         return False;
      end if;

      --  A slash before the colon is a local path such as ./a:b or /tmp/a:b.
      if Slash /= 0 and then Slash < Colon then
         return False;
      end if;

      return True;
   end Is_Scp_Like_Ssh;

   function Detect_Transport (Url : String) return Transport_Kind is
   begin
      if Url'Length = 0 or else Contains_Control (Url) then
         return Unsupported_Transport;
      end if;

      if Starts_With (Url, "http://")
        or else Starts_With (Url, "https://")
      then
         return Http_Transport;
      elsif Starts_With (Url, "ssh://") then
         return Ssh_Transport;
      elsif Starts_With (Url, "file://") then
         if Url'Length = 7 then
            return Unsupported_Transport;
         end if;

         return Local_Transport;
      elsif Has_Scheme (Url) then
         return Unsupported_Transport;
      elsif Is_Scp_Like_Ssh (Url) then
         return Ssh_Transport;
      else
         return Local_Transport;
      end if;
   end Detect_Transport;

   procedure Require_Supported_Url (Url : String) is
   begin
      if Detect_Transport (Url) = Unsupported_Transport then
         raise Ada.IO_Exceptions.Data_Error with
           "unsupported or unsafe remote URL: " & Url;
      end if;
   end Require_Supported_Url;

   function Strip_File_Scheme (Url : String) return String is
      Prefix : constant String := "file://";

      function Hex_Value (C : Character) return Natural is
      begin
         case C is
            when '0' .. '9' =>
               return Character'Pos (C) - Character'Pos ('0');
            when 'A' .. 'F' =>
               return 10 + Character'Pos (C) - Character'Pos ('A');
            when 'a' .. 'f' =>
               return 10 + Character'Pos (C) - Character'Pos ('a');
            when others =>
               raise Ada.IO_Exceptions.Data_Error with
                 "invalid percent escape in file URL: " & Url;
         end case;
      end Hex_Value;

      function Percent_Decode (Value : String) return String is
         Result : String (1 .. Value'Length);
         Last   : Natural := 0;
         I      : Natural := Value'First;
      begin
         while I <= Value'Last loop
            if Value (I) = '%' then
               if I + 2 > Value'Last then
                  raise Ada.IO_Exceptions.Data_Error with
                    "truncated percent escape in file URL: " & Url;
               end if;

               Last := Last + 1;
               Result (Last) := Character'Val
                 (Hex_Value (Value (I + 1)) * 16 + Hex_Value (Value (I + 2)));
               I := I + 3;
            else
               Last := Last + 1;
               Result (Last) := Value (I);
               I := I + 1;
            end if;
         end loop;

         return Result (1 .. Last);
      end Percent_Decode;
   begin
      if Starts_With (Url, Prefix) then
         declare
            Raw : constant String := Url (Url'First + Prefix'Length .. Url'Last);
            Decoded : constant String := Percent_Decode (Raw);
            Localhost : constant String := "localhost/";
         begin
            if Decoded'Length > Localhost'Length
              and then Decoded
                (Decoded'First .. Decoded'First + Localhost'Length - 1)
                = Localhost
            then
               return Decoded
                 (Decoded'First + Localhost'Length - 1 .. Decoded'Last);
            end if;

            if Decoded'Length > 0
              and then Decoded (Decoded'First) /= '/'
              and then not Version.Platform.Is_Windows_Drive_Path (Decoded)
            then
               raise Ada.IO_Exceptions.Data_Error with
                 "unsupported file URL authority: " & Url;
            end if;

            --  RFC-style Windows file URIs are commonly written as
            --  file:///C:/repo.  After removing file:// that leaves /C:/repo,
            --  which is not a usable Windows drive path.  Drop only this
            --  synthetic leading slash; ordinary POSIX file:///tmp paths stay
            --  /tmp.
            if Decoded'Length >= 4
              and then Decoded (Decoded'First) = '/'
              and then Version.Platform.Is_Windows_Drive_Path
                (Decoded (Decoded'First + 1 .. Decoded'Last))
            then
               return Decoded (Decoded'First + 1 .. Decoded'Last);
            end if;

            return Decoded;
         end;
      end if;

      return Url;
   end Strip_File_Scheme;

end Version.Transport;
