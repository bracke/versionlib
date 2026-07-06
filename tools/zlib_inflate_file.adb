with Ada.Command_Line;
with Ada.Text_IO;
with Zlib;

procedure Zlib_Inflate_File is
   use type Zlib.Status_Code;
   Status : Zlib.Status_Code;
begin
   if Ada.Command_Line.Argument_Count /= 2 then
      Ada.Text_IO.Put_Line
        ("usage: zlib_inflate_file <input.zlib> <output.bin>");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      return;
   end if;

   Zlib.Inflate_File
     (Input_Path  => Ada.Command_Line.Argument (1),
      Output_Path => Ada.Command_Line.Argument (2),
      Status      => Status);

   if Status /= Zlib.Ok then
      Ada.Text_IO.Put_Line
        ("inflate failed: " & Zlib.Status_Image (Status));
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      return;
   end if;

   Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
end Zlib_Inflate_File;
