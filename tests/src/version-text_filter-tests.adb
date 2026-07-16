with Ada.Directories;
with Ada.Strings.Fixed;
with AUnit.Assertions;    use AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Git_Fixtures;
with Version.Init;
with Version.Repository;
with Version.Restore;
with Version.Stage;
with Version.Test_Support;

package body Version.Text_Filter.Tests is

   use AUnit.Test_Cases.Registration;

   CR : constant Character := Character'Val (13);
   LF : constant Character := Character'Val (10);

   procedure Configure (Root : String) is
   begin
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");
   end Configure;

   --  core.autocrlf=true: staging a CRLF file stores an LF-normalized blob
   --  (byte-identical to git's), and status treats the CRLF worktree as clean.
   procedure Autocrlf_Checkin_Normalizes_And_Status_Clean
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Configure (Root);
      Version.Git_Fixtures.Run (Root, "git config core.autocrlf true");
      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "a.txt"),
         "line1" & CR & LF & "line2" & CR & LF);

      Version.Stage.Stage_Path ("a.txt");

      --  The stored blob is the LF-normalized content (no CR), matching what
      --  git stores for the same CRLF file under core.autocrlf=true.
      Version.Git_Fixtures.Run
        (Root,
         "git cat-file -p :a.txt > got.txt && "
         & "printf 'line1\nline2\n' > want.txt && cmp got.txt want.txt");
      --  The CRLF worktree file is not reported modified against the index
      --  (git normalizes it the same way; the worktree column stays clean).
      Version.Git_Fixtures.Run (Root, "git diff --quiet a.txt");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Autocrlf_Checkin_Normalizes_And_Status_Clean;

   --  .gitattributes per-path overrides beat core.autocrlf: `-text` disables
   --  normalization (CRLF preserved in the blob) and `eol=lf` forces LF --
   --  both stored byte-identically to git's blobs.
   procedure Gitattributes_Text_Eol_Overrides_Match_Git
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Configure (Root);
      Version.Git_Fixtures.Run (Root, "git config core.autocrlf true");
      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, ".gitattributes"),
         "*.bin -text" & LF & "*.lf text eol=lf" & LF);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "f.bin"),
         "x" & CR & LF & "y" & CR & LF);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "f.lf"),
         "x" & CR & LF & "y" & CR & LF);

      Version.Stage.Stage_Path (".gitattributes");
      Version.Stage.Stage_Path ("f.bin");
      Version.Stage.Stage_Path ("f.lf");

      --  `-text`: normalization disabled, CRLF preserved in the blob.
      Version.Git_Fixtures.Run
        (Root,
         "git cat-file -p :f.bin > gb.txt && "
         & "printf 'x\r\ny\r\n' > wb.txt && cmp gb.txt wb.txt");
      --  `eol=lf`: normalized to LF regardless of core.autocrlf.
      Version.Git_Fixtures.Run
        (Root,
         "git cat-file -p :f.lf > gl.txt && "
         & "printf 'x\ny\n' > wl.txt && cmp gl.txt wl.txt");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Gitattributes_Text_Eol_Overrides_Match_Git;

   --  Nested .gitattributes: a subdirectory's file overrides the root's rule
   --  for paths under it (git's per-directory attribute stacking). Root says
   --  `* text` (normalize), sub/.gitattributes says `*.txt -text` (preserve);
   --  the sub blob keeps CRLF while a root-level file is normalized to LF --
   --  both byte-identical to git's blobs.
   procedure Nested_Gitattributes_Subdir_Overrides_Root
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Configure (Root);
      Version.Git_Fixtures.Run (Root, "git config core.autocrlf false");
      Ada.Directories.Set_Directory (Root);

      --  Root normalizes every text file to LF; the subdir turns it back off.
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, ".gitattributes"),
         "* text" & LF);
      Ada.Directories.Create_Directory
        (Version.Test_Support.Join (Root, "sub"));
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "sub/.gitattributes"),
         "*.txt -text" & LF);

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "top.txt"),
         "a" & CR & LF & "b" & CR & LF);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "sub/inner.txt"),
         "a" & CR & LF & "b" & CR & LF);

      Version.Stage.Stage_Path (".gitattributes");
      Version.Stage.Stage_Path ("sub/.gitattributes");
      Version.Stage.Stage_Path ("top.txt");
      Version.Stage.Stage_Path ("sub/inner.txt");

      --  Root file: `* text` normalizes CRLF -> LF in the blob.
      Version.Git_Fixtures.Run
        (Root,
         "git cat-file -p :top.txt > gt.txt && "
         & "printf 'a\nb\n' > wt.txt && cmp gt.txt wt.txt");
      --  Nested override: `*.txt -text` under sub/ preserves CRLF in the blob.
      Version.Git_Fixtures.Run
        (Root,
         "git cat-file -p :sub/inner.txt > gi.txt && "
         & "printf 'a\r\nb\r\n' > wi.txt && cmp gi.txt wi.txt");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Nested_Gitattributes_Subdir_Overrides_Root;

   --  core.autocrlf=true: checking a file out expands its LF blob to CRLF.
   procedure Autocrlf_Checkout_Expands_To_CRLF
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Configure (Root);
      Ada.Directories.Set_Directory (Root);

      --  Commit an LF blob (autocrlf still off at creation time).
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "a.txt"), "one" & LF & "two" & LF);
      Version.Stage.Stage_Path ("a.txt");
      Version.Git_Fixtures.Run (Root, "git commit -q -m c1");

      --  Turn on autocrlf, drop the working file, and check it back out.
      Version.Git_Fixtures.Run (Root, "git config core.autocrlf true");
      Ada.Directories.Delete_File
        (Version.Test_Support.Join (Root, "a.txt"));
      Version.Restore.Restore_Path_From_Index (Version.Repository.Open, "a.txt");

      --  The materialized file must now use CRLF line endings.
      declare
         Content : constant String :=
           Version.Test_Support.Read_Text_File
             (Version.Test_Support.Join (Root, "a.txt"));
         Has_CRLF : Boolean := False;
      begin
         for I in Content'First .. Content'Last - 1 loop
            if Content (I) = CR and then Content (I + 1) = LF then
               Has_CRLF := True;
            end if;
         end loop;
         Assert (Has_CRLF, "checkout under core.autocrlf=true must emit CRLF");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Autocrlf_Checkout_Expands_To_CRLF;

   --  `ident`: check-in collapses `$Id:...$` -> `$Id$` (byte-identical to git),
   --  and checkout expands `$Id$` -> `$Id: <blob-sha> $`, round-tripping clean.
   procedure Ident_Filter_Matches_Git
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Configure (Root);
      Version.Git_Fixtures.Run (Root, "git config core.autocrlf false");
      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, ".gitattributes"), "*.c ident" & LF);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "f.c"),
         "a $Id: stale $ b" & LF & "$Id$" & LF & "n $Identity$ n" & LF);

      Version.Stage.Stage_Path (".gitattributes");
      Version.Stage.Stage_Path ("f.c");

      --  Check-in collapses to `$Id$`; `$Identity$` is left alone.
      Version.Git_Fixtures.Run
        (Root,
         "git cat-file -p :f.c > got && "
         & "printf 'a $Id$ b\n$Id$\nn $Identity$ n\n' > want && cmp got want");

      Version.Git_Fixtures.Run (Root, "git commit -q -m c1");
      Ada.Directories.Delete_File (Version.Test_Support.Join (Root, "f.c"));
      Version.Restore.Restore_Path_From_Index (Version.Repository.Open, "f.c");

      --  Checkout expanded the ident; the worktree now round-trips clean.
      Version.Git_Fixtures.Run (Root, "git diff --quiet f.c");
      declare
         Content : constant String :=
           Version.Test_Support.Read_Text_File
             (Version.Test_Support.Join (Root, "f.c"));
      begin
         Assert
           (Ada.Strings.Fixed.Index (Content, "$Id: ") > 0,
            "checkout must expand $Id$ to $Id: <sha> $");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Ident_Filter_Matches_Git;

   --  Macro attributes: a `[attr]NAME ...` definition expands when a rule
   --  references NAME, matching git (custom binary + custom text macros).
   procedure Macro_Attributes_Match_Git
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Configure (Root);
      Version.Git_Fixtures.Run (Root, "git config core.autocrlf true");
      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, ".gitattributes"),
         "[attr]keepbin -text" & LF & "[attr]forcetext text eol=lf" & LF
         & "*.bin keepbin" & LF & "*.tx forcetext" & LF);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "a.bin"),
         "x" & CR & LF & "y" & CR & LF);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "b.tx"),
         "x" & CR & LF & "y" & CR & LF);

      Version.Stage.Stage_Path (".gitattributes");
      Version.Stage.Stage_Path ("a.bin");
      Version.Stage.Stage_Path ("b.tx");

      --  keepbin expands to -text: CRLF preserved despite autocrlf=true.
      Version.Git_Fixtures.Run
        (Root,
         "git cat-file -p :a.bin > ga && printf 'x\r\ny\r\n' > wa && cmp ga wa");
      --  forcetext expands to text eol=lf: normalized to LF.
      Version.Git_Fixtures.Run
        (Root,
         "git cat-file -p :b.tx > gb && printf 'x\ny\n' > wb && cmp gb wb");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Macro_Attributes_Match_Git;

   overriding procedure Register_Tests (T : in out Test_Case) is
   begin
      Register_Routine
        (T, Autocrlf_Checkin_Normalizes_And_Status_Clean'Access,
         "Text_Filter: autocrlf check-in normalizes to LF, status clean");
      Register_Routine
        (T, Ident_Filter_Matches_Git'Access,
         "Text_Filter: ident clean/smudge matches git");
      Register_Routine
        (T, Macro_Attributes_Match_Git'Access,
         "Text_Filter: [attr] macro expansion matches git");
      Register_Routine
        (T, Autocrlf_Checkout_Expands_To_CRLF'Access,
         "Text_Filter: autocrlf checkout expands LF to CRLF");
      Register_Routine
        (T, Gitattributes_Text_Eol_Overrides_Match_Git'Access,
         "Text_Filter: .gitattributes -text/eol=lf overrides match git");
      Register_Routine
        (T, Nested_Gitattributes_Subdir_Overrides_Root'Access,
         "Text_Filter: nested subdir .gitattributes overrides root, match git");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Text_Filter");
   end Name;

end Version.Text_Filter.Tests;
