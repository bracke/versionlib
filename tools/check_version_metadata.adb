with Ada.Command_Line;
with Ada.Strings.Fixed;
with Ada.Text_IO;

with Project_Tools.Files;
with Project_Tools.Release_Checks;

--  Verify versionlib's own version metadata is internally consistent:
--  Version.Version_String (src/version.ads) must match alire.toml and be
--  mentioned in README.md and CHANGELOG.md. Independent of the version crate.
procedure Check_Version_Metadata is
   function Trim (Value : String) return String is
   begin
      return Ada.Strings.Fixed.Trim (Value, Ada.Strings.Both);
   end Trim;

   function Quoted_Value_After (Line, Marker : String) return String is
      Marker_Index : constant Natural := Ada.Strings.Fixed.Index (Line, Marker);
   begin
      if Marker_Index = 0 then
         return "";
      end if;
      declare
         Start_Search : constant Positive := Marker_Index + Marker'Length;
         First_Quote  : Natural := 0;
         Last_Quote   : Natural := 0;
      begin
         for I in Start_Search .. Line'Last loop
            if Line (I) = '"' then
               First_Quote := I;
               exit;
            end if;
         end loop;
         if First_Quote = 0 then
            return "";
         end if;
         for I in First_Quote + 1 .. Line'Last loop
            if Line (I) = '"' then
               Last_Quote := I;
               exit;
            end if;
         end loop;
         if Last_Quote = 0 then
            return "";
         end if;
         return Line (First_Quote + 1 .. Last_Quote - 1);
      end;
   end Quoted_Value_After;

   function Source_Version return String is
      File : Ada.Text_IO.File_Type;
   begin
      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, "src/version.ads");
      while not Ada.Text_IO.End_Of_File (File) loop
         declare
            Line  : constant String := Ada.Text_IO.Get_Line (File);
            Value : constant String := Quoted_Value_After (Line, ":=");
         begin
            if Ada.Strings.Fixed.Index (Line, "Version_String") /= 0
              and then Value /= ""
            then
               Ada.Text_IO.Close (File);
               return Value;
            end if;
         end;
      end loop;
      Ada.Text_IO.Close (File);
      return "";
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         return "";
   end Source_Version;

   function Alire_Version return String is
      File : Ada.Text_IO.File_Type;
      Key  : constant String := "version";
   begin
      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, "alire.toml");
      while not Ada.Text_IO.End_Of_File (File) loop
         declare
            Line : constant String := Trim (Ada.Text_IO.Get_Line (File));
         begin
            if Line'Length >= Key'Length
              and then Line (Line'First .. Line'First + Key'Length - 1) = Key
            then
               declare
                  Value : constant String := Quoted_Value_After (Line, "=");
               begin
                  if Value /= "" then
                     Ada.Text_IO.Close (File);
                     return Value;
                  end if;
               end;
            end if;
         end;
      end loop;
      Ada.Text_IO.Close (File);
      return "";
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         return "";
   end Alire_Version;

   procedure Require_Mention (Path, Version : String) is
   begin
      if not Project_Tools.Files.File_Contains (Path, Version) then
         Project_Tools.Release_Checks.Fail
           (Path & " does not mention release version " & Version);
      end if;
   end Require_Mention;

   Source : constant String := Source_Version;
   Alire  : constant String := Alire_Version;
begin
   if Ada.Command_Line.Argument_Count /= 0 then
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error, "usage: check_version_metadata");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      return;
   end if;

   if Source = "" then
      Project_Tools.Release_Checks.Fail
        ("could not read Version.Version_String from src/version.ads");
   end if;

   if Source /= Alire then
      Project_Tools.Release_Checks.Fail
        ("Version.Version_String (" & Source
         & ") does not match alire.toml (" & Alire & ")");
   end if;

   Require_Mention ("README.md", Source);
   Require_Mention ("CHANGELOG.md", Source);

   Ada.Text_IO.Put_Line ("version metadata is consistent: " & Source);
   Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
exception
   when Program_Error =>
      null;  -- Release_Checks.Fail already set the failure exit status
end Check_Version_Metadata;
