with Ada.Command_Line;
with Ada.Directories;
with Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Text_IO;

with Project_Tools.Files;
with Project_Tools.Processes;
with Project_Tools.Release_Checks;

--  End-to-end zlib smoke test for versionlib: deflate then inflate a file via
--  the zlib_* helper tools and confirm the round-trip matches. Run from the
--  versionlib crate root.
procedure Smoke_Test is
   use type Ada.Streams.Stream_Element_Array;
   use type Ada.Streams.Stream_Element_Offset;
   use type Ada.Streams.Stream_IO.Count;

   Tmp        : constant String := "/tmp/versionlib-zlib-smoke-ada";
   Input      : constant String := Tmp & "/hello.txt";
   Compressed : constant String := Tmp & "/hello.zlib";
   Output     : constant String := Tmp & "/hello.out";

   procedure Run_Checked (Command, Message : String) is
   begin
      if Project_Tools.Processes.Run_Shell (Command) /= 0 then
         Project_Tools.Release_Checks.Fail (Message);
      end if;
   end Run_Checked;

   function Same_File (Left, Right : String) return Boolean is
      Left_File  : Ada.Streams.Stream_IO.File_Type;
      Right_File : Ada.Streams.Stream_IO.File_Type;
   begin
      Ada.Streams.Stream_IO.Open
        (Left_File, Ada.Streams.Stream_IO.In_File, Left);
      Ada.Streams.Stream_IO.Open
        (Right_File, Ada.Streams.Stream_IO.In_File, Right);

      if Ada.Streams.Stream_IO.Size (Left_File)
        /= Ada.Streams.Stream_IO.Size (Right_File)
      then
         Ada.Streams.Stream_IO.Close (Left_File);
         Ada.Streams.Stream_IO.Close (Right_File);
         return False;
      end if;

      while not Ada.Streams.Stream_IO.End_Of_File (Left_File) loop
         declare
            Left_Buffer  : Ada.Streams.Stream_Element_Array (1 .. 4096);
            Right_Buffer : Ada.Streams.Stream_Element_Array (1 .. 4096);
            Left_Last    : Ada.Streams.Stream_Element_Offset;
            Right_Last   : Ada.Streams.Stream_Element_Offset;
         begin
            Ada.Streams.Stream_IO.Read (Left_File, Left_Buffer, Left_Last);
            Ada.Streams.Stream_IO.Read (Right_File, Right_Buffer, Right_Last);
            if Left_Last /= Right_Last
              or else Left_Buffer (1 .. Left_Last) /= Right_Buffer (1 .. Right_Last)
            then
               Ada.Streams.Stream_IO.Close (Left_File);
               Ada.Streams.Stream_IO.Close (Right_File);
               return False;
            end if;
         end;
      end loop;

      Ada.Streams.Stream_IO.Close (Left_File);
      Ada.Streams.Stream_IO.Close (Right_File);
      return True;
   exception
      when others =>
         if Ada.Streams.Stream_IO.Is_Open (Left_File) then
            Ada.Streams.Stream_IO.Close (Left_File);
         end if;
         if Ada.Streams.Stream_IO.Is_Open (Right_File) then
            Ada.Streams.Stream_IO.Close (Right_File);
         end if;
         return False;
   end Same_File;

   procedure Write_Text (Path, Text : String) is
      File : Ada.Text_IO.File_Type;
   begin
      Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Path);
      Ada.Text_IO.Put (File, Text);
      Ada.Text_IO.Close (File);
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         raise;
   end Write_Text;
begin
   if Ada.Command_Line.Argument_Count /= 0 then
      Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, "usage: smoke_test");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      return;
   end if;

   Project_Tools.Files.Delete_Tree (Tmp);
   Ada.Directories.Create_Path (Tmp);
   Write_Text (Input, "hello");

   declare
      Deflate_Command : constant String :=
        "./tools/bin/zlib_deflate_stored_file "
        & Project_Tools.Processes.Shell_Quote (Input) & " "
        & Project_Tools.Processes.Shell_Quote (Compressed);
      Inflate_Command : constant String :=
        "./tools/bin/zlib_inflate_file "
        & Project_Tools.Processes.Shell_Quote (Compressed) & " "
        & Project_Tools.Processes.Shell_Quote (Output);
   begin
      Run_Checked
        (Deflate_Command, "zlib smoke command failed: " & Deflate_Command);
      Run_Checked
        (Inflate_Command, "zlib smoke command failed: " & Inflate_Command);
   end;

   if not Same_File (Input, Output) then
      Project_Tools.Release_Checks.Fail ("zlib smoke output did not match input");
   end if;

   Project_Tools.Files.Delete_Tree (Tmp);
   Ada.Text_IO.Put_Line ("zlib smoke test passed");
   Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
exception
   when Program_Error =>
      Project_Tools.Files.Delete_Tree (Tmp);  -- failure status already set
   when others =>
      Project_Tools.Files.Delete_Tree (Tmp);
      raise;
end Smoke_Test;
