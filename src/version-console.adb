with Ada.Text_IO;
with Interfaces.C_Streams;

package body Version.Console is

   procedure Put (Item : String) is
      use type Interfaces.C_Streams.size_t;

      Length  : constant Interfaces.C_Streams.size_t :=
        Interfaces.C_Streams.size_t (Item'Length);
      Written : Interfaces.C_Streams.size_t;
   begin
      if Item'Length = 0 then
         return;
      end if;

      --  Flush any buffered Text_IO output first so ordering is preserved,
      --  then write the payload bytes straight to the C stream.
      --
      --  Ada.Text_IO.Text_Streams would write the same bytes, but GNAT's
      --  stream write puts the handle into binary mode for the call and back
      --  into *text* mode afterwards. On a host that translates (Windows)
      --  that left every later Ada.Text_IO.Put_Line writing CRLF while this
      --  wrote LF -- two spellings of the same output in one stream, where
      --  git writes LF on every host. Writing through the C stream leaves
      --  the mode alone, so Version.Platform's one-time switch holds.
      Ada.Text_IO.Flush (Ada.Text_IO.Standard_Output);

      Written :=
        Interfaces.C_Streams.fwrite
          (buffer => Item'Address,
           size   => 1,
           count  => Length,
           stream => Interfaces.C_Streams.stdout);

      if Written /= Length then
         raise Ada.Text_IO.Device_Error;
      end if;
   end Put;

end Version.Console;
