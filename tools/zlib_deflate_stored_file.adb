with Ada.Command_Line;
with Ada.Text_IO;
with Zlib;

procedure Zlib_Deflate_Stored_File is
   use type Zlib.Status_Code;
   Status : Zlib.Status_Code;
begin
   if Ada.Command_Line.Argument_Count /= 2 then
      Ada.Text_IO.Put_Line
        ("usage: zlib_deflate_stored_file <input.bin> <output.zlib>");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      return;
   end if;

   Zlib.Deflate_Stored_File
     (Input_Path  => Ada.Command_Line.Argument (1),
      Output_Path => Ada.Command_Line.Argument (2),
      Status      => Status);

   if Status /= Zlib.Ok then
      Ada.Text_IO.Put_Line
        ("deflate stored failed: " & Zlib.Status_Image (Status));
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      return;
   end if;

   Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
end Zlib_Deflate_Stored_File;
