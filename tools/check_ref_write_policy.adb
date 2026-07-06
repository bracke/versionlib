with Ada.Command_Line;
with Ada.Directories;
with Ada.Text_IO;

with Project_Tools.Files;
with Project_Tools.Text;

--  Guard ref-mutation hygiene for versionlib's sources: only Version.Refs may
--  call Atomic_Write_Ref directly; every other production source must use the
--  expected-old transaction / HEAD helpers. Scans versionlib's own src/.
procedure Check_Ref_Write_Policy is
   Failed : Boolean := False;

   function Is_Ada_Source (Name : String) return Boolean is
   begin
      return Project_Tools.Text.Ends_With (Name, ".adb")
        or else Project_Tools.Text.Ends_With (Name, ".ads");
   end Is_Ada_Source;

   procedure Check_Source_File (Path, Name : String) is
      Text : constant String := Project_Tools.Files.Read_Raw_File (Path);
   begin
      if Project_Tools.Text.Index (Text, "Atomic_Write_Ref") /= 0
        and then Name /= "version-refs.adb"
        and then Name /= "version-refs.ads"
      then
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error,
            "direct Atomic_Write_Ref use outside Version.Refs: " & Path);
         Failed := True;
      end if;
   end Check_Source_File;

   procedure Scan (Dir : String) is
      Search    : Ada.Directories.Search_Type;
      Dir_Entry : Ada.Directories.Directory_Entry_Type;
      Opened    : Boolean := False;
   begin
      Ada.Directories.Start_Search
        (Search    => Search,
         Directory => Dir,
         Pattern   => "*",
         Filter    =>
           [Ada.Directories.Ordinary_File => True,
            Ada.Directories.Directory     => False,
            Ada.Directories.Special_File  => False]);
      Opened := True;
      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Dir_Entry);
         declare
            Name : constant String := Ada.Directories.Simple_Name (Dir_Entry);
            Path : constant String := Ada.Directories.Full_Name (Dir_Entry);
         begin
            if Is_Ada_Source (Name) then
               Check_Source_File (Path, Name);
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
   end Scan;
begin
   if Ada.Command_Line.Argument_Count /= 0 then
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error, "usage: check_ref_write_policy");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      return;
   end if;

   Project_Tools.Files.Require_Directory ("src", "missing source directory: src");
   Scan ("src");

   if Failed then
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   else
      Ada.Text_IO.Put_Line ("ref write policy checks passed");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
   end if;
exception
   when Program_Error =>
      null;  -- Require_Directory already set the failure exit status
end Check_Ref_Write_Policy;
