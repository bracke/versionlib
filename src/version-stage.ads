package Version.Stage is

   --  Stage the working-tree state of Path (git's `add`). Chmod is
   --  `--chmod=+x`/`-x` ('+' / '-', else ' '): the index mode is set
   --  regardless of the file's own bits. Intent_To_Add is `add -N`: an
   --  untracked path is recorded with an empty blob and the intent-to-add
   --  bit instead of its content (a tracked path is left as it is).
   procedure Stage_Path
     (Path          : String;
      Chmod         : Character := ' ';
      Intent_To_Add : Boolean := False);

end Version.Stage;
