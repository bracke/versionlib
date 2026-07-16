with Ada.Text_IO;
with Ada.Text_IO.Text_Streams;

package body Version.Console is

   procedure Put (Item : String) is
      Out_Stream : constant Ada.Text_IO.Text_Streams.Stream_Access :=
        Ada.Text_IO.Text_Streams.Stream (Ada.Text_IO.Standard_Output);
   begin
      --  Flush any buffered Text_IO output first so ordering is preserved,
      --  then write the payload bytes directly to the underlying stream.
      Ada.Text_IO.Flush (Ada.Text_IO.Standard_Output);
      String'Write (Out_Stream, Item);
   end Put;

end Version.Console;
