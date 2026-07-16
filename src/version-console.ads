package Version.Console is

   procedure Put (Item : String);
   --  Write Item verbatim to standard output. Unlike Ada.Text_IO.Put, this
   --  leaves the runtime's line state untouched, so GNAT does not append a
   --  spurious line terminator at program exit. That matches git's
   --  byte-exact output: no trailing blank line after line-oriented output
   --  (status, log, diff, show) and no forced newline on content that lacks
   --  one (e.g. `cat-file -p` of a blob without a final newline).
   --
   --  Callers must route a command's entire standard-output stream through
   --  this procedure (not interleave it with Ada.Text_IO.Put), otherwise a
   --  preceding Text_IO write can still leave the cursor mid-line.

end Version.Console;
