with Ada.Directories;
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

   overriding procedure Register_Tests (T : in out Test_Case) is
   begin
      Register_Routine
        (T, Autocrlf_Checkin_Normalizes_And_Status_Clean'Access,
         "Text_Filter: autocrlf check-in normalizes to LF, status clean");
      Register_Routine
        (T, Autocrlf_Checkout_Expands_To_CRLF'Access,
         "Text_Filter: autocrlf checkout expands LF to CRLF");
      Register_Routine
        (T, Gitattributes_Text_Eol_Overrides_Match_Git'Access,
         "Text_Filter: .gitattributes -text/eol=lf overrides match git");
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
