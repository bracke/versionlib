with Ada.Directories;
with Ada.Environment_Variables;
with GNAT.OS_Lib;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Git_Fixtures;
with Version.Config;
with Version.Repository;
with Version.Status; use Version.Status;
with Version.Test_Support;
with Version.Platform;

package body Version.Ignore.Tests is

   use AUnit.Assertions;
   use type Version.Platform.Platform_Kind;

   function Has_Change
     (List : Version.Status.File_Change_Vectors.Vector;
      Path : String;
      Kind : Version.Status.Change_Kind) return Boolean is
   begin
      if List.Is_Empty then
         return False;
      end if;

      for I in List.First_Index .. List.Last_Index loop
         if To_String (List.Element (I).Path) = Path
           and then List.Element (I).Kind = Kind
         then
            return True;
         end if;
      end loop;

      return False;
   end Has_Change;

   function Git_Check_Ignored (Root : String; Path : String) return Boolean is
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Status  : Integer;
      Args    : GNAT.OS_Lib.Argument_List :=
        [1 => new String'("check-ignore"),
         2 => new String'("-q"),
         3 => new String'("--"),
         4 => new String'(Path)];
   begin
      Ada.Directories.Set_Directory (Root);
      Status := GNAT.OS_Lib.Spawn (Program_Name => "/usr/bin/git", Args => Args);
      Ada.Directories.Set_Directory (Old_Dir);

      for I in Args'Range loop
         GNAT.OS_Lib.Free (Args (I));
      end loop;

      return Status = 0;

   exception
      when others =>
         if Ada.Directories.Current_Directory /= Old_Dir then
            Ada.Directories.Set_Directory (Old_Dir);
         end if;

         for I in Args'Range loop
            GNAT.OS_Lib.Free (Args (I));
         end loop;
         raise;
   end Git_Check_Ignored;

   procedure Init_Empty_Repo (Root : String) is
   begin
      Version.Git_Fixtures.Run (Root, "git init");
      Version.Git_Fixtures.Run
        (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");
   end Init_Empty_Repo;

   procedure Basic_Rule_Matching (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Init_Empty_Repo (Root);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, ".gitignore"),
         "# comment"
         & Character'Val (10)
         & Character'Val (10)
         & "*.o"
         & Character'Val (10)
         & "build/"
         & Character'Val (10)
         & "/root.tmp"
         & Character'Val (10)
         & "!important.o"
         & Character'Val (10));

      Ada.Directories.Set_Directory (Root);

      declare
         Repo  : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Rules : constant Version.Ignore.Ignore_Rules :=
           Version.Ignore.Load (Repo);
      begin
         Assert
           (Version.Ignore.Is_Ignored (Rules, "main.o", False),
            "wildcard suffix should ignore root object file");
         Assert
           (Version.Ignore.Is_Ignored (Rules, "src/main.o", False),
            "wildcard suffix should ignore nested object file");
         Assert
           (Version.Ignore.Is_Ignored (Rules, "build/generated.txt", False),
            "directory rule should ignore contents");
         Assert
           (Version.Ignore.Is_Ignored (Rules, "root.tmp", False),
            "anchored root file should match root path");
         Assert
           (not Version.Ignore.Is_Ignored (Rules, "src/root.tmp", False),
            "anchored root file should not match nested path");
         Assert
           (not Version.Ignore.Is_Ignored (Rules, "important.o", False),
            "later negation should unignore file");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Basic_Rule_Matching;

   procedure Slash_And_Nested_Rules
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Docs    : constant String := Version.Test_Support.Join (Root, "docs");
      Logs    : constant String := Version.Test_Support.Join (Docs, "logs");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Init_Empty_Repo (Root);
      Version.Test_Support.Make_Directory (Docs);
      Version.Test_Support.Make_Directory (Logs);

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, ".gitignore"),
         "docs/*.tmp" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Docs, ".gitignore"),
         "logs/**/*.log"
         & Character'Val (10)
         & "!logs/keep.log"
         & Character'Val (10));

      Ada.Directories.Set_Directory (Root);

      declare
         Repo  : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Rules : constant Version.Ignore.Ignore_Rules :=
           Version.Ignore.Load (Repo);
      begin
         Assert
           (Version.Ignore.Is_Ignored (Rules, "docs/a.tmp", False),
            "slash pattern should match relative to gitignore base");
         Assert
           (not Version.Ignore.Is_Ignored (Rules, "x/docs/a.tmp", False),
            "slash pattern should not float outside its base");
         Assert
           (Version.Ignore.Is_Ignored
              (Rules, "docs/logs/deep/error.log", False),
            "nested gitignore with double-star should match descendants");
         Assert
           (not Version.Ignore.Is_Ignored (Rules, "docs/logs/keep.log", False),
            "nested later negation should unignore matching descendant");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Slash_And_Nested_Rules;

   procedure Escaped_Slash_Rules_Match_Git
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;

      procedure Check
        (Rules    : Version.Ignore.Ignore_Rules;
         Path     : String;
         Expected : Boolean;
         Message  : String)
      is
      begin
         Assert
           (Version.Ignore.Is_Ignored (Rules, Path, False) = Expected,
            Message);
         Assert
           (Version.Ignore.Is_Ignored (Rules, Path, False)
            = Git_Check_Ignored (Root, Path),
            Message & " should match git check-ignore");
      end Check;
   begin
      Init_Empty_Repo (Root);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, ".gitignore"),
         "foo\/bar"
         & Character'Val (10)
         & "nested\/keep.txt"
         & Character'Val (10)
         & "\/root"
         & Character'Val (10));

      Ada.Directories.Set_Directory (Root);

      declare
         Repo  : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Rules : constant Version.Ignore.Ignore_Rules :=
           Version.Ignore.Load (Repo);
      begin
         Check
           (Rules,
            "foo/bar",
            True,
            "escaped slash should still match a path separator");
         Check
           (Rules,
            "other/foo/bar",
            False,
            "escaped slash pattern should remain path-relative");
         Check
           (Rules,
            "nested/keep.txt",
            True,
            "escaped slash should work in multi-component patterns");
         Check
           (Rules,
            "root",
            False,
            "escaped leading slash should not become root anchoring");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Escaped_Slash_Rules_Match_Git;

   procedure Double_Star_Rules_Match_Git
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;

      procedure Check
        (Rules : Version.Ignore.Ignore_Rules; Path : String; Message : String)
      is
      begin
         Assert
           (Version.Ignore.Is_Ignored (Rules, Path, False)
            = Git_Check_Ignored (Root, Path),
            Message);
      end Check;

      procedure Check_Directory
        (Rules : Version.Ignore.Ignore_Rules; Path : String; Message : String)
      is
      begin
         Assert
           (Version.Ignore.Is_Ignored (Rules, Path, True)
            = Git_Check_Ignored (Root, Path & "/"),
            Message);
      end Check_Directory;
   begin
      Init_Empty_Repo (Root);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, ".gitignore"),
         "**/target.log"
         & Character'Val (10)
         & "build/**/cache"
         & Character'Val (10)
         & "a**b"
         & Character'Val (10)
         & "foo/**bar"
         & Character'Val (10)
         & "triple/***bar"
         & Character'Val (10)
         & "assets/**"
         & Character'Val (10)
         & "!assets/keep.txt"
         & Character'Val (10));

      Ada.Directories.Set_Directory (Root);

      declare
         Repo  : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Rules : constant Version.Ignore.Ignore_Rules :=
           Version.Ignore.Load (Repo);
      begin
         Check (Rules, "target.log", "leading ** should match root basename");
         Check
           (Rules, "src/deep/target.log",
            "leading ** should match nested basename");
         Check (Rules, "build/cache", "middle ** should allow zero directories");
         Check
           (Rules, "build/a/b/cache",
            "middle ** should match multiple directories");
         Check (Rules, "ab", "non-special ** should still match zero characters");
         Check
           (Rules, "axb",
            "non-special ** should match ordinary non-slash characters");
         Check
           (Rules, "a/x/b",
            "non-special ** should not cross path separators");
         Check
           (Rules, "foo/bar",
            "slash-adjacent non-special ** should match zero characters");
         Check
           (Rules, "foo/xxbar",
            "slash-adjacent non-special ** should match non-slash text");
         Check
           (Rules, "foo/x/bar",
            "slash-adjacent non-special ** should not recurse into directories");
         Check
           (Rules, "triple/starbar",
            "triple-star after slash should match ordinary non-slash text");
         Check
           (Rules, "triple/x/starbar",
            "triple-star after slash should not recurse into directories");
         Check_Directory
           (Rules, "assets",
            "trailing ** should match the directory when queried as a directory");
         Check
           (Rules, "assets",
            "trailing ** should not match the directory when queried as a file path");
         Check
           (Rules, "assets/file.txt",
            "trailing ** should match direct child paths");
         Check
           (Rules, "assets/deep/file.txt",
            "trailing ** should match descendant paths");
         Check
           (Rules, "assets/keep.txt",
            "later negation should override trailing ** match");
         Check
           (Rules, "other/target.txt",
            "double-star patterns should not match unrelated names");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Double_Star_Rules_Match_Git;

   procedure Escaped_Prefixes_And_Trailing_Spaces
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Init_Empty_Repo (Root);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, ".gitignore"),
         "\#literal"
         & Character'Val (10)
         & "\!literal"
         & Character'Val (10)
         & "space\ "
         & Character'Val (10)
         & "file\ with\ spaces.tmp"
         & Character'Val (10)
         & " leading-space.tmp"
         & Character'Val (10)
         & "trimmed   "
         & Character'Val (10)
         & "tabbed"
         & Character'Val (9)
         & Character'Val (10)
         & "\*.literal"
         & Character'Val (10)
         & "\?.literal"
         & Character'Val (10)
         & "\[abc].literal"
         & Character'Val (10)
         & "literal\\slash"
         & Character'Val (10)
         & "trailing\\"
         & Character'Val (10)
         & "ordinary\q"
         & Character'Val (10));

      Ada.Directories.Set_Directory (Root);

      declare
         Repo  : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Rules : constant Version.Ignore.Ignore_Rules :=
           Version.Ignore.Load (Repo);
      begin
         Assert
           (Version.Ignore.Is_Ignored (Rules, "#literal", False),
            "escaped leading # should be a literal pattern, not a comment");
         Assert
           (Version.Ignore.Is_Ignored (Rules, "#literal", False)
            = Git_Check_Ignored (Root, "#literal"),
            "escaped leading # should match git check-ignore");
         Assert
           (Version.Ignore.Is_Ignored (Rules, "!literal", False),
            "escaped leading ! should be a literal pattern, not negation");
         Assert
           (Version.Ignore.Is_Ignored (Rules, "!literal", False)
            = Git_Check_Ignored (Root, "!literal"),
            "escaped leading ! should match git check-ignore");
         Assert
           (Version.Ignore.Is_Ignored (Rules, "space ", False),
            "escaped trailing space should remain part of the pattern");
         Assert
           (Version.Ignore.Is_Ignored (Rules, "space ", False)
            = Git_Check_Ignored (Root, "space "),
            "escaped trailing space should match git check-ignore");
         Assert
           (not Version.Ignore.Is_Ignored (Rules, "space", False),
            "escaped trailing space should not match the trimmed spelling");
         Assert
           (Version.Ignore.Is_Ignored (Rules, "file with spaces.tmp", False),
            "escaped spaces should remain literal path characters");
         Assert
           (Version.Ignore.Is_Ignored (Rules, "file with spaces.tmp", False)
            = Git_Check_Ignored (Root, "file with spaces.tmp"),
            "escaped space pattern should match git check-ignore");
         Assert
           (Version.Ignore.Is_Ignored (Rules, " leading-space.tmp", False),
            "leading spaces should remain literal path characters");
         Assert
           (Version.Ignore.Is_Ignored (Rules, " leading-space.tmp", False)
            = Git_Check_Ignored (Root, " leading-space.tmp"),
            "leading-space pattern should match git check-ignore");
         Assert
           (not Version.Ignore.Is_Ignored (Rules, "leading-space.tmp", False),
            "leading-space pattern should not match trimmed path");
         Assert
           (Version.Ignore.Is_Ignored (Rules, "trimmed", False),
            "unescaped trailing spaces should be stripped");
         Assert
           (Version.Ignore.Is_Ignored (Rules, "trimmed", False)
            = Git_Check_Ignored (Root, "trimmed"),
            "unescaped trailing spaces should match git check-ignore");
         Assert
           (not Version.Ignore.Is_Ignored (Rules, "tabbed", False),
            "unescaped trailing tabs should not be stripped");
         Assert
           (Version.Ignore.Is_Ignored
              (Rules, "tabbed" & Character'Val (9), False)
            = Git_Check_Ignored (Root, "tabbed" & Character'Val (9)),
            "unescaped trailing tabs should match git check-ignore literally");
         Assert
           (Version.Ignore.Is_Ignored (Rules, "*.literal", False)
            = Git_Check_Ignored (Root, "*.literal"),
            "escaped star should match git check-ignore as a literal");
         Assert
           (not Version.Ignore.Is_Ignored (Rules, "x.literal", False),
            "escaped star should not act as a wildcard");
         Assert
           (Version.Ignore.Is_Ignored (Rules, "?.literal", False)
            = Git_Check_Ignored (Root, "?.literal"),
            "escaped question mark should match git check-ignore as a literal");
         Assert
           (Version.Ignore.Is_Ignored (Rules, "[abc].literal", False)
            = Git_Check_Ignored (Root, "[abc].literal"),
            "escaped opening bracket should match git check-ignore as a literal");
         Assert
           (Version.Ignore.Is_Ignored (Rules, "literal\slash", False),
            "escaped backslash should match a literal backslash path");
         Assert
           (Version.Ignore.Is_Ignored (Rules, "literal\slash", False)
            = Git_Check_Ignored (Root, "literal\slash"),
            "escaped backslash should match git check-ignore as a literal");
         Assert
           (Version.Ignore.Is_Ignored (Rules, "trailing\", False),
            "trailing escaped backslash should match a literal backslash path");
         Assert
           (Version.Ignore.Is_Ignored (Rules, "trailing\", False)
            = Git_Check_Ignored (Root, "trailing\"),
            "trailing escaped backslash should match git check-ignore");
         Assert
           (Version.Ignore.Is_Ignored (Rules, "ordinaryq", False),
            "backslash before ordinary character should escape that character");
         Assert
           (Version.Ignore.Is_Ignored (Rules, "ordinaryq", False)
            = Git_Check_Ignored (Root, "ordinaryq"),
            "ordinary-character backslash escape should match git check-ignore");
         Assert
           (not Version.Ignore.Is_Ignored (Rules, "ordinary\q", False),
            "backslash before ordinary character should not remain literal");
         Assert
           (Version.Ignore.Is_Ignored (Rules, "ordinary\q", False)
            = Git_Check_Ignored (Root, "ordinary\q"),
            "literal ordinary-character backslash path should match git check-ignore");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Escaped_Prefixes_And_Trailing_Spaces;

   procedure CRLF_Ignore_File_Matches_Git
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      CR      : constant Character := Character'Val (13);
      LF      : constant Character := Character'Val (10);
   begin
      Init_Empty_Repo (Root);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, ".gitignore"),
         "crlf.tmp"
         & CR
         & LF
         & "nested/*.tmp"
         & CR
         & LF
         & "!nested/keep.tmp"
         & CR
         & LF);

      Ada.Directories.Set_Directory (Root);

      declare
         Repo  : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Rules : constant Version.Ignore.Ignore_Rules :=
           Version.Ignore.Load (Repo);
      begin
         Assert
           (Version.Ignore.Is_Ignored (Rules, "crlf.tmp", False),
            "CRLF gitignore line should ignore literal pattern");
         Assert
           (Version.Ignore.Is_Ignored (Rules, "nested/file.tmp", False),
            "CRLF gitignore line should ignore slash pattern");
         Assert
           (not Version.Ignore.Is_Ignored (Rules, "nested/keep.tmp", False),
            "CRLF gitignore line should preserve negation");
         Assert
           (Version.Ignore.Is_Ignored (Rules, "crlf.tmp", False)
            = Git_Check_Ignored (Root, "crlf.tmp"),
            "CRLF literal pattern should match git check-ignore");
         Assert
           (Version.Ignore.Is_Ignored (Rules, "nested/file.tmp", False)
            = Git_Check_Ignored (Root, "nested/file.tmp"),
            "CRLF slash pattern should match git check-ignore");
         Assert
           (Version.Ignore.Is_Ignored (Rules, "nested/keep.tmp", False)
            = Git_Check_Ignored (Root, "nested/keep.tmp"),
            "CRLF negation should match git check-ignore");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end CRLF_Ignore_File_Matches_Git;

   procedure UTF8_BOM_Ignore_File_Matches_Git
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      BOM     : constant String :=
        Character'Val (16#EF#)
        & Character'Val (16#BB#)
        & Character'Val (16#BF#);
   begin
      Init_Empty_Repo (Root);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, ".gitignore"),
         BOM
         & "bom.tmp"
         & Character'Val (10)
         & "normal.tmp"
         & Character'Val (10));

      Ada.Directories.Set_Directory (Root);

      declare
         Repo  : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Rules : constant Version.Ignore.Ignore_Rules :=
           Version.Ignore.Load (Repo);
      begin
         Assert
           (Version.Ignore.Is_Ignored (Rules, "bom.tmp", False)
            = Git_Check_Ignored (Root, "bom.tmp"),
            "UTF-8 BOM on first gitignore line should be stripped");
         Assert
           (Version.Ignore.Is_Ignored (Rules, "normal.tmp", False)
            = Git_Check_Ignored (Root, "normal.tmp"),
            "patterns after a BOM-prefixed first line should still load");
         Assert
           (not Version.Ignore.Is_Ignored (Rules, BOM & "bom.tmp", False),
            "BOM bytes should not remain part of the first pattern");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end UTF8_BOM_Ignore_File_Matches_Git;

   procedure Symlinked_Gitignore_Files_Are_Not_Loaded
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Sub     : constant String := Version.Test_Support.Join (Root, "sub");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Init_Empty_Repo (Root);
      Version.Test_Support.Make_Directory (Sub);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "root-ignore-target"),
         "root-linked-only.tmp" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "nested-ignore-target"),
         "nested-linked-only.tmp" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "ln -s root-ignore-target .gitignore");
      Version.Git_Fixtures.Run (Root, "ln -s ../nested-ignore-target sub/.gitignore");

      Ada.Directories.Set_Directory (Root);

      declare
         Repo  : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Rules : constant Version.Ignore.Ignore_Rules :=
           Version.Ignore.Load (Repo);
      begin
         Assert
           (not Version.Ignore.Is_Ignored (Rules, "root-linked-only.tmp", False),
            "symlinked root .gitignore should not be loaded");
         Assert
           (Version.Ignore.Is_Ignored (Rules, "root-linked-only.tmp", False)
            = Git_Check_Ignored (Root, "root-linked-only.tmp"),
            "symlinked root .gitignore behavior should match git check-ignore");
         Assert
           (not Version.Ignore.Is_Ignored
              (Rules, "sub/nested-linked-only.tmp", False),
            "symlinked nested .gitignore should not be loaded");
         Assert
           (Version.Ignore.Is_Ignored
              (Rules, "sub/nested-linked-only.tmp", False)
            = Git_Check_Ignored (Root, "sub/nested-linked-only.tmp"),
            "symlinked nested .gitignore behavior should match git check-ignore");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Symlinked_Gitignore_Files_Are_Not_Loaded;

   procedure Directory_Name_Rule_Ignores_Descendants
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Init_Empty_Repo (Root);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, ".gitignore"),
         "cache" & Character'Val (10) & "*" & Character'Val (10));

      Ada.Directories.Set_Directory (Root);

      declare
         Repo  : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Rules : constant Version.Ignore.Ignore_Rules :=
           Version.Ignore.Load (Repo);
      begin
         Assert
           (Version.Ignore.Is_Ignored (Rules, "cache/generated.txt", False),
            "basename directory rule without trailing slash should ignore descendants");
         Assert
           (not Version.Ignore.Is_Ignored (Rules, ".git/config", False),
            ".git internals must never be classified as ignored working-tree paths");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Directory_Name_Rule_Ignores_Descendants;

   procedure Parent_Directory_Exclusion_Prevents_File_Reinclude
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Build   : constant String := Version.Test_Support.Join (Root, "build");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Init_Empty_Repo (Root);
      Version.Test_Support.Make_Directory (Build);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, ".gitignore"),
         "build/"
         & Character'Val (10)
         & "!build/keep.txt"
         & Character'Val (10)
         & "obj/*"
         & Character'Val (10)
         & "!obj/keep.txt"
         & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Build, ".gitignore"),
         "!rescued.txt" & Character'Val (10));

      Ada.Directories.Set_Directory (Root);

      declare
         Repo  : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Rules : constant Version.Ignore.Ignore_Rules :=
           Version.Ignore.Load (Repo);
      begin
         Assert
           (Version.Ignore.Is_Ignored (Rules, "build/keep.txt", False),
            "file negation must not re-include a child of an ignored directory");
         Assert
           (not Version.Ignore.Is_Ignored (Rules, "obj/keep.txt", False),
            "file negation may re-include when only directory contents are ignored");
         Assert
           (Version.Ignore.Is_Ignored (Rules, "build/rescued.txt", False),
            "nested gitignore negation must not re-include below ignored parent");
         Assert
           (Version.Ignore.Is_Ignored (Rules, "build/rescued.txt", False)
            = Git_Check_Ignored (Root, "build/rescued.txt"),
            "nested gitignore negation below ignored parent should match git");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Parent_Directory_Exclusion_Prevents_File_Reinclude;

   procedure Directory_Only_Rule_Does_Not_Ignore_File
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Init_Empty_Repo (Root);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, ".gitignore"),
         "cache/" & Character'Val (10));

      Ada.Directories.Set_Directory (Root);

      declare
         Repo  : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Rules : constant Version.Ignore.Ignore_Rules :=
           Version.Ignore.Load (Repo);
      begin
         Assert
           (not Version.Ignore.Is_Ignored (Rules, "cache", False),
            "directory-only rule must not ignore a file with the same name");
         Assert
           (Version.Ignore.Is_Ignored (Rules, "cache", True),
            "directory-only rule should ignore a directory with the same name");
         Assert
           (Version.Ignore.Is_Ignored (Rules, "cache/generated.txt", False),
            "directory-only rule should ignore descendants of the directory");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Directory_Only_Rule_Does_Not_Ignore_File;

   procedure Core_Ignore_Case_Matches_Git
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Sub     : constant String := Version.Test_Support.Join (Root, "sub");
      Old_Dir : constant String := Ada.Directories.Current_Directory;

      procedure Check
        (Rules : Version.Ignore.Ignore_Rules; Path : String; Message : String)
      is
      begin
         Assert
           (Version.Ignore.Is_Ignored (Rules, Path, False)
            = Git_Check_Ignored (Root, Path),
            Message);
      end Check;
   begin
      Init_Empty_Repo (Root);
      Version.Test_Support.Make_Directory (Sub);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, ".gitignore"),
         "Build/"
         & Character'Val (10)
         & "*.TMP"
         & Character'Val (10)
         & "[[:upper:]].upper"
         & Character'Val (10)
         & "[A-C].range"
         & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Sub, ".gitignore"),
         "Nested/" & Character'Val (10));

      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
      begin
         Version.Config.Set_Key (Repo, "core.ignoreCase", "true");
      end;

      declare
         Repo  : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Rules : constant Version.Ignore.Ignore_Rules :=
           Version.Ignore.Load (Repo);
      begin
         Check
           (Rules, "build/file.txt",
            "core.ignoreCase should match directory rules case-insensitively");
         Check
           (Rules, "a.tmp",
            "core.ignoreCase should match suffix globs case-insensitively");
         Check
           (Rules, "z.upper",
            "core.ignoreCase should match POSIX upper classes case-insensitively");
         Check
           (Rules, "b.range",
            "core.ignoreCase should match bracket ranges case-insensitively");
         Check
           (Rules, "d.range",
            "core.ignoreCase should still reject characters outside bracket ranges");
         Check
           (Rules, "sub/nested/file.txt",
            "core.ignoreCase should match nested patterns after exact base match");
         Check
           (Rules, "SUB/nested/file.txt",
            "core.ignoreCase should not make nested gitignore base paths float");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Core_Ignore_Case_Matches_Git;

   procedure Core_Ignore_Case_Config_Stack_Matches_Git
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root          : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Global_Config : constant String :=
        Version.Test_Support.Join (Root, "global-config");
      Included_Config : constant String :=
        Version.Test_Support.Join (Root, "included-config");
      Old_Dir       : constant String := Ada.Directories.Current_Directory;
      Global_Exists : constant Boolean :=
        Ada.Environment_Variables.Exists ("GIT_CONFIG_GLOBAL");
      Global_Value  : constant String :=
        (if Global_Exists then Ada.Environment_Variables.Value ("GIT_CONFIG_GLOBAL") else "");
      No_System_Exists : constant Boolean :=
        Ada.Environment_Variables.Exists ("GIT_CONFIG_NOSYSTEM");
      No_System_Value  : constant String :=
        (if No_System_Exists then Ada.Environment_Variables.Value ("GIT_CONFIG_NOSYSTEM") else "");
      Env_Count_Exists : constant Boolean :=
        Ada.Environment_Variables.Exists ("GIT_CONFIG_COUNT");
      Env_Count_Value  : constant String :=
        (if Env_Count_Exists then Ada.Environment_Variables.Value ("GIT_CONFIG_COUNT") else "");
      Env_Key_0_Exists : constant Boolean :=
        Ada.Environment_Variables.Exists ("GIT_CONFIG_KEY_0");
      Env_Key_0_Value  : constant String :=
        (if Env_Key_0_Exists then Ada.Environment_Variables.Value ("GIT_CONFIG_KEY_0") else "");
      Env_Value_0_Exists : constant Boolean :=
        Ada.Environment_Variables.Exists ("GIT_CONFIG_VALUE_0");
      Env_Value_0_Value  : constant String :=
        (if Env_Value_0_Exists then Ada.Environment_Variables.Value ("GIT_CONFIG_VALUE_0") else "");

      procedure Restore_Env is
      begin
         if Global_Exists then
            Ada.Environment_Variables.Set ("GIT_CONFIG_GLOBAL", Global_Value);
         else
            Ada.Environment_Variables.Clear ("GIT_CONFIG_GLOBAL");
         end if;

         if No_System_Exists then
            Ada.Environment_Variables.Set ("GIT_CONFIG_NOSYSTEM", No_System_Value);
         else
            Ada.Environment_Variables.Clear ("GIT_CONFIG_NOSYSTEM");
         end if;

         if Env_Count_Exists then
            Ada.Environment_Variables.Set ("GIT_CONFIG_COUNT", Env_Count_Value);
         else
            Ada.Environment_Variables.Clear ("GIT_CONFIG_COUNT");
         end if;

         if Env_Key_0_Exists then
            Ada.Environment_Variables.Set ("GIT_CONFIG_KEY_0", Env_Key_0_Value);
         else
            Ada.Environment_Variables.Clear ("GIT_CONFIG_KEY_0");
         end if;

         if Env_Value_0_Exists then
            Ada.Environment_Variables.Set ("GIT_CONFIG_VALUE_0", Env_Value_0_Value);
         else
            Ada.Environment_Variables.Clear ("GIT_CONFIG_VALUE_0");
         end if;
      end Restore_Env;

      procedure Check (Path : String; Expected : Boolean; Message : String) is
      begin
         Ada.Directories.Set_Directory (Root);
         declare
            Repo  : constant Version.Repository.Repository_Handle :=
              Version.Repository.Open;
            Rules : constant Version.Ignore.Ignore_Rules :=
              Version.Ignore.Load (Repo);
         begin
            Assert
              (Version.Ignore.Is_Ignored (Rules, Path, False) = Expected,
               Message);
            Assert
              (Version.Ignore.Is_Ignored (Rules, Path, False)
               = Git_Check_Ignored (Root, Path),
               Message & " should match git check-ignore");
         end;
         Ada.Directories.Set_Directory (Old_Dir);
      end Check;
   begin
      Init_Empty_Repo (Root);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, ".gitignore"),
         "Build/" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Included_Config,
         "[core]" & Character'Val (10)
         & Character'Val (9) & "ignoreCase" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Global_Config,
         "[include]" & Character'Val (10)
         & Character'Val (9) & "path = " & Character'Val (34)
         & Included_Config & Character'Val (34) & Character'Val (10));

      Ada.Environment_Variables.Set ("GIT_CONFIG_GLOBAL", Global_Config);
      Ada.Environment_Variables.Set ("GIT_CONFIG_NOSYSTEM", "1");
      Ada.Environment_Variables.Clear ("GIT_CONFIG_COUNT");
      Ada.Environment_Variables.Clear ("GIT_CONFIG_KEY_0");
      Ada.Environment_Variables.Clear ("GIT_CONFIG_VALUE_0");
      Check ("build/file.txt", True,
             "included global core.ignoreCase should affect ignore matching");

      Version.Test_Support.Write_Text_File
        (Included_Config,
         "[core]" & Character'Val (10)
         & Character'Val (9) & "ignoreCase = " & Character'Val (34)
         & "true" & Character'Val (34) & Character'Val (10));
      Check ("build/file.txt", True,
             "quoted file core.ignoreCase true should affect ignore matching");

      Ada.Directories.Set_Directory (Root);
      Version.Config.Set_Key
        (Version.Repository.Open, "core.ignoreCase", "false");
      Ada.Directories.Set_Directory (Old_Dir);
      Check ("build/file.txt", False,
             "local core.ignoreCase false should override global true");

      Ada.Environment_Variables.Set ("GIT_CONFIG_COUNT", "1");
      Ada.Environment_Variables.Set ("GIT_CONFIG_KEY_0", "core.ignoreCase");
      Ada.Environment_Variables.Set ("GIT_CONFIG_VALUE_0", "true");
      Check ("build/file.txt", True,
             "GIT_CONFIG_COUNT core.ignoreCase should override local config");

      Ada.Environment_Variables.Set ("GIT_CONFIG_VALUE_0", "");
      Check ("build/file.txt", False,
             "empty GIT_CONFIG_COUNT core.ignoreCase should be false");

      Ada.Environment_Variables.Set
        ("GIT_CONFIG_VALUE_0", Character'Val (34) & "true" & Character'Val (34));
      Check ("build/file.txt", False,
             "quoted GIT_CONFIG_COUNT core.ignoreCase should remain a raw value");

      Restore_Env;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         if Ada.Directories.Current_Directory /= Old_Dir then
            Ada.Directories.Set_Directory (Old_Dir);
         end if;
         Restore_Env;
         raise;
   end Core_Ignore_Case_Config_Stack_Matches_Git;

   procedure Dot_Segment_Query_Paths_Match_Git
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;

      procedure Check
        (Rules : Version.Ignore.Ignore_Rules; Path : String; Message : String)
      is
      begin
         Assert
           (Version.Ignore.Is_Ignored (Rules, Path, False)
            = Git_Check_Ignored (Root, Path),
            Message);
      end Check;
   begin
      Init_Empty_Repo (Root);
      Version.Test_Support.Make_Directory
        (Version.Test_Support.Join (Root, "sub"));
      Version.Test_Support.Make_Directory
        (Version.Test_Support.Join (Root, "build"));
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, ".gitignore"),
         "/root.tmp"
         & Character'Val (10)
         & "sub/*.tmp"
         & Character'Val (10)
         & "build/"
         & Character'Val (10));

      Ada.Directories.Set_Directory (Root);

      declare
         Repo  : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Rules : constant Version.Ignore.Ignore_Rules :=
           Version.Ignore.Load (Repo);
      begin
         Check
           (Rules, "./root.tmp",
            "leading dot segment should not block anchored root pattern");
         Check
           (Rules, "sub/./a.tmp",
            "embedded dot segment should not block slash pattern");
         Check
           (Rules, "./sub/./a.tmp",
            "combined leading and embedded dot segments should normalize");
         Check
           (Rules, "build/./file",
            "dot segment below directory rule should normalize");
         Check
           (Rules, "./build/./file",
            "leading dot segment below directory rule should normalize");
         Check
           (Rules, Version.Test_Support.Join (Root, "root.tmp"),
            "absolute in-repository root path should normalize");
         Check
           (Rules, Version.Test_Support.Join (Root, "sub/a.tmp"),
            "absolute in-repository slash pattern path should normalize");
         Check
           (Rules, Root & "//sub//a.tmp",
            "absolute in-repository path with repeated separators should normalize");
         Check
           (Rules, "sub/../root.tmp",
            "safe parent segment should normalize to anchored root pattern");
         Check
           (Rules, "build/../sub/a.tmp",
            "safe parent segment should normalize before slash pattern matching");
         Check
           (Rules, "sub/../build/file",
            "safe parent segment should normalize before directory matching");
         Assert
           (not Version.Ignore.Is_Ignored (Rules, "../outside.tmp", False),
            "escaping parent segment should not classify an outside path as ignored");
         Assert
           (not Version.Ignore.Is_Ignored
              (Rules, Version.Test_Support.Join (Old_Dir, "outside.tmp"), False),
            "absolute outside path should not classify as ignored");
         Assert
           (not Version.Ignore.Is_Ignored
              (Rules, "sub/../../outside.tmp", False),
            "deep escaping parent segment should not classify an outside path as ignored");
         Assert
           (not Version.Ignore.Is_Ignored (Rules, "./.git/config", False),
            "normalized git internals must remain protected");
         Assert
           (not Version.Ignore.Is_Ignored (Rules, "sub/../.git/config", False),
            "parent-normalized git internals must remain protected");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Dot_Segment_Query_Paths_Match_Git;

   procedure Load_Relative_Root_Normalizes_Absolute_Queries
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Init_Empty_Repo (Root);
      Version.Test_Support.Make_Directory
        (Version.Test_Support.Join (Root, "sub"));
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, ".gitignore"),
         "root-only.tmp" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join
           (Version.Test_Support.Join (Root, "sub"), ".gitignore"),
         "*.tmp" & Character'Val (10));

      Ada.Directories.Set_Directory (Root);

      declare
         Rules : constant Version.Ignore.Ignore_Rules := Version.Ignore.Load (".");
         Path  : constant String := Version.Test_Support.Join (Root, "sub/a.tmp");
      begin
         Assert
           (Version.Ignore.Is_Ignored (Rules, "root-only.tmp", False),
            "Load with relative root should keep root .gitignore rules relative");
         Assert
           (Version.Ignore.Is_Ignored (Rules, "sub/a.tmp", False),
            "Load with relative root should keep nested .gitignore bases relative");
         Assert
           (Version.Ignore.Is_Ignored (Rules, Path, False)
            = Git_Check_Ignored (Root, Path),
            "Load with relative root should normalize absolute in-repo queries");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Load_Relative_Root_Normalizes_Absolute_Queries;

   procedure Bracket_Character_Class_Rules
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Init_Empty_Repo (Root);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, ".gitignore"),
         "[ab].tmp"
         & Character'Val (10)
         & "range-[0-9].log"
         & Character'Val (10)
         & "not-[!x].dat"
         & Character'Val (10)
         & "not-[^x].caret"
         & Character'Val (10)
         & "[]]bracket.txt"
         & Character'Val (10)
         & "dash[-]name.txt"
         & Character'Val (10)
         & "esc[\!]name.txt"
         & Character'Val (10)
         & "[[:digit:]].log"
         & Character'Val (10)
         & "[[:alpha:]].dat"
         & Character'Val (10)
         & "[![:space:]].txt"
         & Character'Val (10)
         & "hex-[[:xdigit:]].txt"
         & Character'Val (10)
         & "[abc"
         & Character'Val (10));

      Ada.Directories.Set_Directory (Root);

      declare
         Repo  : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Rules : constant Version.Ignore.Ignore_Rules :=
           Version.Ignore.Load (Repo);

         procedure Check
           (Path : String; Expected : Boolean; Message : String) is
         begin
            Assert
              (Version.Ignore.Is_Ignored (Rules, Path, False) = Expected,
               Message);
            Assert
              (Version.Ignore.Is_Ignored (Rules, Path, False)
               = Git_Check_Ignored (Root, Path),
               Message & " should match git check-ignore");
         end Check;
      begin
         Check
           ("a.tmp", True,
            "positive bracket class should match listed character");
         Check
           ("dir/b.tmp", True,
            "basename bracket class should match nested basename");
         Check
           ("c.tmp", False,
            "positive bracket class should reject non-listed character");
         Check
           ("range-7.log", True,
            "bracket ranges should match included characters");
         Check
           ("range-x.log", False,
            "bracket ranges should reject excluded characters");
         Check
           ("not-y.dat", True,
            "bang-negated bracket class should match outside characters");
         Check
           ("not-x.dat", False,
            "bang-negated bracket class should reject inside characters");
         Check
           ("not-y.caret", True,
            "caret-negated bracket class should match outside characters");
         Check
           ("not-x.caret", False,
            "caret-negated bracket class should reject inside characters");
         Check
           ("]bracket.txt", True,
            "closing bracket should be literal when first in a character class");
         Check
           ("dash-name.txt", True,
            "dash should be literal in a singleton character class");
         Check
           ("esc!name.txt", True,
            "escaped class characters should match literally");
         Check
           ("7.log", True,
            "POSIX digit class should match digits");
         Check
           ("a.log", False,
            "POSIX digit class should reject letters");
         Check
           ("a.dat", True,
            "POSIX alpha class should match letters");
         Check
           ("7.dat", False,
            "POSIX alpha class should reject digits");
         Check
           ("x.txt", True,
            "negated POSIX space class should match non-space characters");
         Check
           (" .txt", False,
            "negated POSIX space class should reject spaces");
         Check
           ("hex-f.txt", True,
            "POSIX xdigit class should match hexadecimal letters");
         Check
           ("hex-g.txt", False,
            "POSIX xdigit class should reject non-hexadecimal letters");
         Check
           ("[abc", False,
            "unterminated bracket class should not match literally");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Bracket_Character_Class_Rules;

   procedure Git_Check_Ignore_Core_Compatibility
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Docs    : constant String := Version.Test_Support.Join (Root, "docs");
      Logs    : constant String := Version.Test_Support.Join (Root, "logs");
      Deep    : constant String := Version.Test_Support.Join (Logs, "deep");
      Foo     : constant String := Version.Test_Support.Join (Root, "foo");
      Wild_Dir : constant String := Version.Test_Support.Join (Root, "objects.dir");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Init_Empty_Repo (Root);
      Version.Test_Support.Make_Directory (Docs);
      Version.Test_Support.Make_Directory (Logs);
      Version.Test_Support.Make_Directory (Deep);
      Version.Test_Support.Make_Directory (Foo);
      Version.Test_Support.Make_Directory (Wild_Dir);

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, ".gitignore"),
         "*.o"
         & Character'Val (10)
         & "build/"
         & Character'Val (10)
         & "/root.tmp"
         & Character'Val (10)
         & "docs/*.tmp"
         & Character'Val (10)
         & "logs/**/*.log"
         & Character'Val (10)
         & "!logs/keep.log"
         & Character'Val (10)
         & "foo"
         & Character'Val (10)
         & "*.dir"
         & Character'Val (10));

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "main.o"), "object");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "root.tmp"), "root");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Docs, "a.tmp"), "tmp");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Deep, "error.log"), "log");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Logs, "keep.log"), "keep");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Foo, "child.txt"), "ignored");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Wild_Dir, "child.txt"), "ignored");

      Ada.Directories.Set_Directory (Root);

      declare
         Rules : constant Version.Ignore.Ignore_Rules :=
           Version.Ignore.Load (Root);
      begin
         Assert
           (Version.Ignore.Is_Ignored (Rules, "main.o", False)
            = Git_Check_Ignored (Root, "main.o"),
            "main.o ignore result should match git check-ignore");
         Assert
           (Version.Ignore.Is_Ignored (Rules, "docs/a.tmp", False)
            = Git_Check_Ignored (Root, "docs/a.tmp"),
            "docs/a.tmp ignore result should match git check-ignore");
         Assert
           (Version.Ignore.Is_Ignored (Rules, "logs/deep/error.log", False)
            = Git_Check_Ignored (Root, "logs/deep/error.log"),
            "logs/deep/error.log ignore result should match git check-ignore");
         Assert
           (Version.Ignore.Is_Ignored (Rules, "logs/keep.log", False)
            = Git_Check_Ignored (Root, "logs/keep.log"),
            "negated keep.log ignore result should match git check-ignore");
         Assert
           (Version.Ignore.Is_Ignored (Rules, "foo/child.txt", False)
            = Git_Check_Ignored (Root, "foo/child.txt"),
            "child below literal ignored directory should match git check-ignore");
         Assert
           (Version.Ignore.Is_Ignored (Rules, "objects.dir/child.txt", False)
            = Git_Check_Ignored (Root, "objects.dir/child.txt"),
            "child below wildcard ignored directory should match git check-ignore");
         Assert
           (Version.Ignore.Is_Ignored (Rules, "src/root.tmp", False)
            = Git_Check_Ignored (Root, "src/root.tmp"),
            "anchored non-match should match git check-ignore");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Git_Check_Ignore_Core_Compatibility;

   procedure Core_Excludes_File_Is_Loaded_First
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root      : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Core_Path : constant String := Version.Test_Support.Join (Root, "core-ignore");
      Old_Dir   : constant String := Ada.Directories.Current_Directory;
   begin
      Init_Empty_Repo (Root);
      Version.Test_Support.Write_Text_File
        (Core_Path,
         "*.cache"
         & Character'Val (10)
         & "core-only.tmp"
         & Character'Val (10));
      Ada.Directories.Set_Directory (Root);
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
      begin
         Version.Config.Set_Key (Repo, "core.excludesFile", Core_Path);
      end;
      Ada.Directories.Set_Directory (Old_Dir);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, ".git/info/exclude"),
         "!info-keep.cache" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, ".gitignore"),
         "!keep.cache" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "scratch.cache"), "ignored");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "core-only.tmp"), "ignored");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "info-keep.cache"), "visible");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "keep.cache"), "visible");

      Ada.Directories.Set_Directory (Root);

      declare
         Repo       : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Repo_Rules : constant Version.Ignore.Ignore_Rules :=
           Version.Ignore.Load (Repo);
         Root_Rules : constant Version.Ignore.Ignore_Rules :=
           Version.Ignore.Load (Root);
      begin
         Assert
           (Version.Ignore.Is_Ignored (Repo_Rules, "scratch.cache", False),
            "core.excludesFile wildcard should ignore matching files");
         Assert
           (Version.Ignore.Is_Ignored (Repo_Rules, "core-only.tmp", False),
            "core.excludesFile literal should ignore matching files");
         Assert
           (not Version.Ignore.Is_Ignored (Repo_Rules, "info-keep.cache", False),
            "info/exclude negation should override core.excludesFile");
         Assert
           (not Version.Ignore.Is_Ignored (Repo_Rules, "keep.cache", False),
            ".gitignore negation should override core.excludesFile");
         Assert
           (Version.Ignore.Is_Ignored (Root_Rules, "scratch.cache", False),
            "root loader should include core.excludesFile rules");
         Assert
           (Version.Ignore.Is_Ignored (Repo_Rules, "scratch.cache", False)
            = Git_Check_Ignored (Root, "scratch.cache"),
            "core.excludesFile wildcard should match git check-ignore");
         Assert
           (Version.Ignore.Is_Ignored (Repo_Rules, "info-keep.cache", False)
            = Git_Check_Ignored (Root, "info-keep.cache"),
            "info/exclude override should match git check-ignore");
         Assert
           (Version.Ignore.Is_Ignored (Repo_Rules, "keep.cache", False)
            = Git_Check_Ignored (Root, "keep.cache"),
            ".gitignore override should match git check-ignore");
      end;

      declare
         Result : constant Version.Status.Status_Result :=
           Version.Status.Current_Status;
      begin
         Assert
           (not Has_Change
                  (Result.Untracked, "scratch.cache", Version.Status.New_File),
            "status must omit files ignored by core.excludesFile");
         Assert
           (not Has_Change
                  (Result.Untracked, "core-only.tmp", Version.Status.New_File),
            "status must omit literal core.excludesFile ignored files");
         Assert
           (Has_Change
              (Result.Untracked, "info-keep.cache", Version.Status.New_File),
            "status must show files re-included by info/exclude");
         Assert
           (Has_Change (Result.Untracked, "keep.cache", Version.Status.New_File),
            "status must show files re-included by .gitignore");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Core_Excludes_File_Is_Loaded_First;

   procedure Core_Excludes_File_Path_Forms
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root          : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Relative_Name : constant String := "relative-ignore";
      Relative_Path : constant String :=
        Version.Test_Support.Join (Root, Relative_Name);
      Prefix_Path   : constant String := Version.Test_Support.Join (Root, "prefix-ignore");
      Home_Dir      : constant String := Version.Test_Support.Join (Root, "home");
      Home_Path     : constant String :=
        Version.Test_Support.Join (Home_Dir, "tilde-ignore");
      Missing_User_Dir : constant String :=
        Version.Test_Support.Join (Root, "~version-test-user-that-should-not-exist");
      Missing_User_Ignore : constant String :=
        Version.Test_Support.Join (Missing_User_Dir, "ignore");
      Quoted_Path   : constant String :=
        Version.Test_Support.Join (Root, "quoted ignore");
      Backspace_Path : constant String :=
        Version.Test_Support.Join
          (Root, "quoted" & Character'Val (8) & "ignore");
      Backspace_Config_Path : constant String :=
        Version.Test_Support.Join (Root, "quoted" & "\bignore");
      Invalid_Escape_Path : constant String :=
        Version.Test_Support.Join (Root, "badqescapeignore");
      Old_Dir       : constant String := Ada.Directories.Current_Directory;
      User_Tilde_Ignore_Name : constant String :=
        "version-test-user-tilde-ignore";
      User_Tilde_Ignore_Path : constant String :=
        Version.Test_Support.Join (Old_Dir, User_Tilde_Ignore_Name);
      User_Tilde_Config_Name : constant String :=
        "version-test-user-tilde-config";
      User_Tilde_Config_Path : constant String :=
        Version.Test_Support.Join (Old_Dir, User_Tilde_Config_Name);
      User_Tilde_Repo_Name : constant String :=
        "version-test-user-tilde-repo";
      User_Tilde_Repo_Path : constant String :=
        Version.Test_Support.Join (Old_Dir, User_Tilde_Repo_Name);
      Home_Exists   : constant Boolean := Ada.Environment_Variables.Exists ("HOME");
      Home_Value    : constant String :=
        (if Home_Exists then Ada.Environment_Variables.Value ("HOME") else "");
      User_Exists   : constant Boolean := Ada.Environment_Variables.Exists ("USER");
      User_Value    : constant String :=
        (if User_Exists then Ada.Environment_Variables.Value ("USER") else "");

      function Starts_With_Path (Path : String; Prefix : String) return Boolean is
      begin
         return
           Prefix'Length > 0
           and then Path'Length > Prefix'Length
           and then Path (Path'First .. Path'First + Prefix'Length - 1) = Prefix
           and then Path (Path'First + Prefix'Length) = '/';
      end Starts_With_Path;

      procedure Remove_User_Tilde_Files is
      begin
         if Ada.Directories.Exists (User_Tilde_Ignore_Path) then
            Ada.Directories.Delete_File (User_Tilde_Ignore_Path);
         end if;

         if Ada.Directories.Exists (User_Tilde_Config_Path) then
            Ada.Directories.Delete_File (User_Tilde_Config_Path);
         end if;

         Version.Test_Support.Cleanup (User_Tilde_Repo_Path);
      exception
         when others =>
            null;
      end Remove_User_Tilde_Files;

      procedure Restore_Home is
      begin
         if Home_Exists then
            Ada.Environment_Variables.Set ("HOME", Home_Value);
         else
            Ada.Environment_Variables.Clear ("HOME");
         end if;
      end Restore_Home;

      procedure Set_Core_Excludes_File (Value : String) is
      begin
         Ada.Directories.Set_Directory (Root);
         declare
            Repo : constant Version.Repository.Repository_Handle :=
              Version.Repository.Open;
         begin
            Version.Config.Set_Key (Repo, "core.excludesFile", Value);
         end;
         Ada.Directories.Set_Directory (Old_Dir);
      end Set_Core_Excludes_File;

      procedure Check_Ignored (Path : String; Message : String) is
      begin
         Ada.Directories.Set_Directory (Root);
         declare
            Repo  : constant Version.Repository.Repository_Handle :=
              Version.Repository.Open;
            Rules : constant Version.Ignore.Ignore_Rules :=
              Version.Ignore.Load (Repo);
         begin
            Assert
              (Version.Ignore.Is_Ignored (Rules, Path, False),
               Message);
            Assert
              (Version.Ignore.Is_Ignored (Rules, Path, False)
               = Git_Check_Ignored (Root, Path),
               Message & " should match git check-ignore");
         end;
         Ada.Directories.Set_Directory (Old_Dir);
      end Check_Ignored;

      procedure Check_Ignored_By_Version_Only (Path : String; Message : String) is
      begin
         Ada.Directories.Set_Directory (Root);
         declare
            Repo  : constant Version.Repository.Repository_Handle :=
              Version.Repository.Open;
            Rules : constant Version.Ignore.Ignore_Rules :=
              Version.Ignore.Load (Repo);
         begin
            Assert
              (Version.Ignore.Is_Ignored (Rules, Path, False),
               Message);
         end;
         Ada.Directories.Set_Directory (Old_Dir);
      end Check_Ignored_By_Version_Only;
   begin
      Init_Empty_Repo (Root);
      Version.Test_Support.Make_Directory (Home_Dir);
      Version.Test_Support.Make_Directory (Missing_User_Dir);
      Version.Test_Support.Write_Text_File
        (Relative_Path, "relative-only.tmp" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Prefix_Path, "prefix-only.tmp" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Home_Path, "tilde-only.tmp" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Missing_User_Ignore, "missing-user-only.tmp" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Quoted_Path, "quoted-only.tmp" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Backspace_Path, "backspace-only.tmp" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Invalid_Escape_Path, "invalid-escape-only.tmp" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "relative-only.tmp"), "ignored");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "prefix-only.tmp"), "ignored");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "tilde-only.tmp"), "ignored");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "missing-user-only.tmp"), "visible");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "quoted-only.tmp"), "ignored");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "invalid-escape-only.tmp"), "visible");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "missing-only.tmp"), "visible");

      Set_Core_Excludes_File (Relative_Name);
      Check_Ignored
        ("relative-only.tmp",
         "repo-relative core.excludesFile path should be loaded");

      Set_Core_Excludes_File ("%(prefix)/prefix-ignore");
      Check_Ignored_By_Version_Only
        ("prefix-only.tmp",
         "prefix-interpolated core.excludesFile path should be loaded");

      Ada.Environment_Variables.Set ("HOME", Home_Dir);
      Set_Core_Excludes_File ("~/tilde-ignore");
      Check_Ignored
        ("tilde-only.tmp",
         "HOME-relative core.excludesFile path should be loaded");

      Set_Core_Excludes_File ("~version-test-user-that-should-not-exist/ignore");
      Ada.Directories.Set_Directory (Root);
      declare
         Repo  : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Rules : constant Version.Ignore.Ignore_Rules :=
           Version.Ignore.Load (Repo);
      begin
         Assert
           (not Version.Ignore.Is_Ignored (Rules, "missing-user-only.tmp", False),
            "unresolved ~user core.excludesFile path should not be treated as repository-relative");
      end;
      Ada.Directories.Set_Directory (Old_Dir);

      if Version.Platform.Current = Version.Platform.POSIX_Platform
        and then User_Exists
        and then Home_Exists
        and then Starts_With_Path (Old_Dir, Home_Value)
      then
         declare
            Relative_To_Home : constant String :=
              Old_Dir (Old_Dir'First + Home_Value'Length + 1 .. Old_Dir'Last);
         begin
            Version.Test_Support.Write_Text_File
              (User_Tilde_Ignore_Path,
               "user-tilde-only.tmp" & Character'Val (10));
            Version.Test_Support.Write_Text_File
              (Version.Test_Support.Join (Root, "user-tilde-only.tmp"),
               "ignored");
            Set_Core_Excludes_File
              ("~" & User_Value & "/" & Relative_To_Home & "/"
               & User_Tilde_Ignore_Name);
            Check_Ignored
              ("user-tilde-only.tmp",
               "user-relative core.excludesFile path should be loaded");

            Version.Test_Support.Write_Text_File
              (User_Tilde_Config_Path,
               "[core]" & Character'Val (10)
               & Character'Val (9)
               & "excludesFile = "
               & Character'Val (34)
               & User_Tilde_Ignore_Path
               & Character'Val (34)
               & Character'Val (10));
            Version.Test_Support.Cleanup (User_Tilde_Repo_Path);
            Version.Test_Support.Make_Directory (User_Tilde_Repo_Path);
            Init_Empty_Repo (User_Tilde_Repo_Path);
            Version.Test_Support.Write_Text_File
              (Version.Test_Support.Join
                 (User_Tilde_Repo_Path, "user-tilde-only.tmp"),
               "ignored");

            declare
               Config_Path : constant String :=
                 Version.Test_Support.Join (User_Tilde_Repo_Path, ".git/config");
               Existing_Config : constant String :=
                 Version.Test_Support.Read_Text_File (Config_Path);
            begin
               Version.Test_Support.Write_Text_File
                 (Config_Path,
                  Existing_Config
                  & Character'Val (10)
                  & "[includeIf "
                  & Character'Val (34)
                  & "gitdir:~" & User_Value & "/"
                  & Character'Val (34)
                  & "]"
                  & Character'Val (10)
                  & Character'Val (9)
                  & "path = "
                  & Character'Val (34)
                  & "~" & User_Value & "/" & Relative_To_Home & "/"
                  & User_Tilde_Config_Name
                  & Character'Val (34)
                  & Character'Val (10));
            end;

            Ada.Directories.Set_Directory (User_Tilde_Repo_Path);
            declare
               Repo  : constant Version.Repository.Repository_Handle :=
                 Version.Repository.Open;
               Rules : constant Version.Ignore.Ignore_Rules :=
                 Version.Ignore.Load (Repo);
            begin
               Assert
                 (Version.Ignore.Is_Ignored
                    (Rules, "user-tilde-only.tmp", False),
                  "includeIf gitdir:~user/ should match recursively and load ~user path");
               Assert
                 (Version.Ignore.Is_Ignored
                    (Rules, "user-tilde-only.tmp", False)
                  = Git_Check_Ignored
                      (User_Tilde_Repo_Path, "user-tilde-only.tmp"),
                  "includeIf gitdir:~user/ should match git check-ignore");
            end;
            Ada.Directories.Set_Directory (Old_Dir);
            Remove_User_Tilde_Files;
         end;
      end if;

      Set_Core_Excludes_File (Character'Val (34) & Quoted_Path & Character'Val (34));
      Check_Ignored
        ("quoted-only.tmp",
         "quoted core.excludesFile path with spaces should be loaded");

      Set_Core_Excludes_File
        (Character'Val (34)
         & Backspace_Config_Path
         & Character'Val (34));
      Check_Ignored
        ("backspace-only.tmp",
         "quoted core.excludesFile path with \b escape should be loaded");

      Set_Core_Excludes_File
        (Character'Val (34)
         & "bad" & "\qescapeignore"
         & Character'Val (34));
      Ada.Directories.Set_Directory (Root);
      declare
         Repo  : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Rules : constant Version.Ignore.Ignore_Rules :=
           Version.Ignore.Load (Repo);
      begin
         Assert
           (not Version.Ignore.Is_Ignored
                  (Rules, "invalid-escape-only.tmp", False),
            "invalid quoted config path escape should not load an ignore file");
         Assert
           (Version.Ignore.Is_Ignored
              (Rules, "invalid-escape-only.tmp", False)
            = Git_Check_Ignored (Root, "invalid-escape-only.tmp"),
            "invalid quoted config path escape should match git check-ignore");
      end;
      Ada.Directories.Set_Directory (Old_Dir);

      Set_Core_Excludes_File ("missing-ignore");
      Ada.Directories.Set_Directory (Root);
      declare
         Repo  : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Rules : constant Version.Ignore.Ignore_Rules :=
           Version.Ignore.Load (Repo);
      begin
         Assert
           (not Version.Ignore.Is_Ignored (Rules, "missing-only.tmp", False),
            "missing core.excludesFile should not add ignore rules");
      end;
      Ada.Directories.Set_Directory (Old_Dir);
      Remove_User_Tilde_Files;
      Restore_Home;
   exception
      when others =>
         if Ada.Directories.Current_Directory /= Old_Dir then
            Ada.Directories.Set_Directory (Old_Dir);
         end if;
         Remove_User_Tilde_Files;
         Restore_Home;
         raise;
   end Core_Excludes_File_Path_Forms;

   procedure Core_Excludes_File_Default_Path
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root          : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Home_Dir      : constant String := Version.Test_Support.Join (Root, "home");
      Home_Config   : constant String :=
        Version.Test_Support.Join (Home_Dir, ".config");
      Home_Git      : constant String :=
        Version.Test_Support.Join (Home_Config, "git");
      XDG_Dir       : constant String := Version.Test_Support.Join (Root, "xdg");
      XDG_Git       : constant String := Version.Test_Support.Join (XDG_Dir, "git");
      Empty_Global  : constant String :=
        Version.Test_Support.Join (Root, "empty-global-config");
      Old_Dir       : constant String := Ada.Directories.Current_Directory;
      Home_Exists   : constant Boolean := Ada.Environment_Variables.Exists ("HOME");
      Home_Value    : constant String :=
        (if Home_Exists then Ada.Environment_Variables.Value ("HOME") else "");
      XDG_Exists    : constant Boolean :=
        Ada.Environment_Variables.Exists ("XDG_CONFIG_HOME");
      XDG_Value     : constant String :=
        (if XDG_Exists then Ada.Environment_Variables.Value ("XDG_CONFIG_HOME") else "");
      Global_Exists : constant Boolean :=
        Ada.Environment_Variables.Exists ("GIT_CONFIG_GLOBAL");
      Global_Value  : constant String :=
        (if Global_Exists then Ada.Environment_Variables.Value ("GIT_CONFIG_GLOBAL") else "");
      No_System_Exists : constant Boolean :=
        Ada.Environment_Variables.Exists ("GIT_CONFIG_NOSYSTEM");
      No_System_Value  : constant String :=
        (if No_System_Exists then Ada.Environment_Variables.Value ("GIT_CONFIG_NOSYSTEM") else "");
      Env_Count_Exists : constant Boolean :=
        Ada.Environment_Variables.Exists ("GIT_CONFIG_COUNT");
      Env_Count_Value  : constant String :=
        (if Env_Count_Exists then Ada.Environment_Variables.Value ("GIT_CONFIG_COUNT") else "");
      Env_Key_0_Exists : constant Boolean :=
        Ada.Environment_Variables.Exists ("GIT_CONFIG_KEY_0");
      Env_Key_0_Value  : constant String :=
        (if Env_Key_0_Exists then Ada.Environment_Variables.Value ("GIT_CONFIG_KEY_0") else "");
      Env_Value_0_Exists : constant Boolean :=
        Ada.Environment_Variables.Exists ("GIT_CONFIG_VALUE_0");
      Env_Value_0_Value  : constant String :=
        (if Env_Value_0_Exists then Ada.Environment_Variables.Value ("GIT_CONFIG_VALUE_0") else "");

      procedure Restore_Env is
      begin
         if Home_Exists then
            Ada.Environment_Variables.Set ("HOME", Home_Value);
         else
            Ada.Environment_Variables.Clear ("HOME");
         end if;

         if XDG_Exists then
            Ada.Environment_Variables.Set ("XDG_CONFIG_HOME", XDG_Value);
         else
            Ada.Environment_Variables.Clear ("XDG_CONFIG_HOME");
         end if;

         if Global_Exists then
            Ada.Environment_Variables.Set ("GIT_CONFIG_GLOBAL", Global_Value);
         else
            Ada.Environment_Variables.Clear ("GIT_CONFIG_GLOBAL");
         end if;

         if No_System_Exists then
            Ada.Environment_Variables.Set ("GIT_CONFIG_NOSYSTEM", No_System_Value);
         else
            Ada.Environment_Variables.Clear ("GIT_CONFIG_NOSYSTEM");
         end if;

         if Env_Count_Exists then
            Ada.Environment_Variables.Set ("GIT_CONFIG_COUNT", Env_Count_Value);
         else
            Ada.Environment_Variables.Clear ("GIT_CONFIG_COUNT");
         end if;

         if Env_Key_0_Exists then
            Ada.Environment_Variables.Set ("GIT_CONFIG_KEY_0", Env_Key_0_Value);
         else
            Ada.Environment_Variables.Clear ("GIT_CONFIG_KEY_0");
         end if;

         if Env_Value_0_Exists then
            Ada.Environment_Variables.Set ("GIT_CONFIG_VALUE_0", Env_Value_0_Value);
         else
            Ada.Environment_Variables.Clear ("GIT_CONFIG_VALUE_0");
         end if;
      end Restore_Env;

      procedure Check (Path : String; Expected : Boolean; Message : String) is
      begin
         Ada.Directories.Set_Directory (Root);
         declare
            Repo  : constant Version.Repository.Repository_Handle :=
              Version.Repository.Open;
            Rules : constant Version.Ignore.Ignore_Rules :=
              Version.Ignore.Load (Repo);
         begin
            Assert
              (Version.Ignore.Is_Ignored (Rules, Path, False) = Expected,
               Message);
            Assert
              (Version.Ignore.Is_Ignored (Rules, Path, False)
               = Git_Check_Ignored (Root, Path),
               Message & " should match git check-ignore");
         end;
         Ada.Directories.Set_Directory (Old_Dir);
      end Check;
   begin
      Init_Empty_Repo (Root);
      Version.Test_Support.Make_Directory (Home_Dir);
      Version.Test_Support.Make_Directory (Home_Config);
      Version.Test_Support.Make_Directory (Home_Git);
      Version.Test_Support.Make_Directory (XDG_Dir);
      Version.Test_Support.Make_Directory (XDG_Git);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Home_Git, "ignore"),
         "home-default.tmp" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (XDG_Git, "ignore"),
         "xdg-default.tmp" & Character'Val (10));
      Version.Test_Support.Write_Text_File (Empty_Global, "");

      Ada.Environment_Variables.Set ("HOME", Home_Dir);
      Ada.Environment_Variables.Set ("XDG_CONFIG_HOME", XDG_Dir);
      Ada.Environment_Variables.Set ("GIT_CONFIG_NOSYSTEM", "1");
      Ada.Environment_Variables.Set ("GIT_CONFIG_GLOBAL", Empty_Global);
      Check ("xdg-default.tmp", True,
             "unset core.excludesFile should use XDG default ignore file");
      Check ("home-default.tmp", False,
             "XDG default ignore file should override HOME default path");

      Ada.Environment_Variables.Set ("XDG_CONFIG_HOME", "");
      Check ("home-default.tmp", True,
             "empty XDG_CONFIG_HOME should fall back to HOME default ignore file");

      Ada.Directories.Set_Directory (Root);
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
      begin
         Version.Config.Set_Key (Repo, "core.excludesFile", "");
      end;
      Ada.Directories.Set_Directory (Old_Dir);
      Ada.Environment_Variables.Set ("XDG_CONFIG_HOME", XDG_Dir);
      Check ("xdg-default.tmp", False,
             "explicit empty core.excludesFile should disable default ignore file");

      Restore_Env;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         if Ada.Directories.Current_Directory /= Old_Dir then
            Ada.Directories.Set_Directory (Old_Dir);
         end if;
         Restore_Env;
         raise;
   end Core_Excludes_File_Default_Path;

   procedure Core_Excludes_File_Config_Stack
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root          : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Home_Dir      : constant String := Version.Test_Support.Join (Root, "home");
      XDG_Dir       : constant String := Version.Test_Support.Join (Root, "xdg");
      XDG_Git_Dir   : constant String := Version.Test_Support.Join (XDG_Dir, "git");
      Empty_XDG_Home_Dir : constant String :=
        Version.Test_Support.Join (Root, "empty-xdg-home");
      Empty_XDG_Home_Config_Dir : constant String :=
        Version.Test_Support.Join (Empty_XDG_Home_Dir, ".config");
      Empty_XDG_Home_Git_Dir : constant String :=
        Version.Test_Support.Join (Empty_XDG_Home_Config_Dir, "git");
      System_Config : constant String := Version.Test_Support.Join (Root, "system-config");
      Env_Global_Config : constant String :=
        Version.Test_Support.Join (Root, "env-global-config");
      Included_Config : constant String :=
        Version.Test_Support.Join (Root, "included-config");
      Conditional_Config : constant String :=
        Version.Test_Support.Join (Root, "conditional-config");
      Nonmatching_Config : constant String :=
        Version.Test_Support.Join (Root, "nonmatching-config");
      Case_Insensitive_Config : constant String :=
        Version.Test_Support.Join (Root, "case-insensitive-config");
      Onbranch_Config : constant String :=
        Version.Test_Support.Join (Root, "onbranch-config");
      Onbranch_Glob_Config : constant String :=
        Version.Test_Support.Join (Root, "onbranch-glob-config");
      Onbranch_Nonmatching_Config : constant String :=
        Version.Test_Support.Join (Root, "onbranch-nonmatching-config");
      Env_Command_Config : constant String :=
        Version.Test_Support.Join (Root, "env-command-config");
      Env_Include_Config : constant String :=
        Version.Test_Support.Join (Root, "env-include-config");
      Env_Onbranch_Config : constant String :=
        Version.Test_Support.Join (Root, "env-onbranch-config");
      Env_Onbranch_Nonmatching_Config : constant String :=
        Version.Test_Support.Join (Root, "env-onbranch-nonmatching-config");
      Local_Included_Config : constant String :=
        Version.Test_Support.Join (Root, "local-included-config");
      System_Ignore : constant String := Version.Test_Support.Join (Root, "system-ignore");
      XDG_Ignore    : constant String := Version.Test_Support.Join (Root, "xdg-ignore");
      Home_Ignore   : constant String := Version.Test_Support.Join (Root, "home-ignore");
      Empty_XDG_Home_Ignore : constant String :=
        Version.Test_Support.Join (Root, "empty-xdg-home-ignore");
      Env_Global_Ignore : constant String :=
        Version.Test_Support.Join (Root, "env-global-ignore");
      Included_Ignore : constant String :=
        Version.Test_Support.Join (Root, "included-ignore");
      Conditional_Ignore : constant String :=
        Version.Test_Support.Join (Root, "conditional-ignore");
      Nonmatching_Ignore : constant String :=
        Version.Test_Support.Join (Root, "nonmatching-ignore");
      Case_Insensitive_Ignore : constant String :=
        Version.Test_Support.Join (Root, "case-insensitive-ignore");
      Onbranch_Ignore : constant String :=
        Version.Test_Support.Join (Root, "onbranch-ignore");
      Onbranch_Glob_Ignore : constant String :=
        Version.Test_Support.Join (Root, "onbranch-glob-ignore");
      Onbranch_Nonmatching_Ignore : constant String :=
        Version.Test_Support.Join (Root, "onbranch-nonmatching-ignore");
      Env_Command_Ignore : constant String :=
        Version.Test_Support.Join (Root, "env-command-ignore");
      Env_Include_Ignore : constant String :=
        Version.Test_Support.Join (Root, "env-include-ignore");
      Env_Onbranch_Ignore : constant String :=
        Version.Test_Support.Join (Root, "env-onbranch-ignore");
      Env_Onbranch_Nonmatching_Ignore : constant String :=
        Version.Test_Support.Join (Root, "env-onbranch-nonmatching-ignore");
      Local_Included_Ignore : constant String :=
        Version.Test_Support.Join (Root, "local-included-ignore");
      Local_Ignore  : constant String := Version.Test_Support.Join (Root, "local-ignore");
      Old_Dir       : constant String := Ada.Directories.Current_Directory;
      Home_Exists   : constant Boolean := Ada.Environment_Variables.Exists ("HOME");
      Home_Value    : constant String :=
        (if Home_Exists then Ada.Environment_Variables.Value ("HOME") else "");
      XDG_Exists    : constant Boolean :=
        Ada.Environment_Variables.Exists ("XDG_CONFIG_HOME");
      XDG_Value     : constant String :=
        (if XDG_Exists then Ada.Environment_Variables.Value ("XDG_CONFIG_HOME") else "");
      System_Exists : constant Boolean :=
        Ada.Environment_Variables.Exists ("GIT_CONFIG_SYSTEM");
      System_Value  : constant String :=
        (if System_Exists then Ada.Environment_Variables.Value ("GIT_CONFIG_SYSTEM") else "");
      Global_Exists : constant Boolean :=
        Ada.Environment_Variables.Exists ("GIT_CONFIG_GLOBAL");
      Global_Value  : constant String :=
        (if Global_Exists then Ada.Environment_Variables.Value ("GIT_CONFIG_GLOBAL") else "");
      No_System_Exists : constant Boolean :=
        Ada.Environment_Variables.Exists ("GIT_CONFIG_NOSYSTEM");
      No_System_Value  : constant String :=
        (if No_System_Exists then Ada.Environment_Variables.Value ("GIT_CONFIG_NOSYSTEM") else "");
      Env_Count_Exists : constant Boolean :=
        Ada.Environment_Variables.Exists ("GIT_CONFIG_COUNT");
      Env_Count_Value  : constant String :=
        (if Env_Count_Exists then Ada.Environment_Variables.Value ("GIT_CONFIG_COUNT") else "");
      Env_Key_0_Exists : constant Boolean :=
        Ada.Environment_Variables.Exists ("GIT_CONFIG_KEY_0");
      Env_Key_0_Value  : constant String :=
        (if Env_Key_0_Exists then Ada.Environment_Variables.Value ("GIT_CONFIG_KEY_0") else "");
      Env_Value_0_Exists : constant Boolean :=
        Ada.Environment_Variables.Exists ("GIT_CONFIG_VALUE_0");
      Env_Value_0_Value  : constant String :=
        (if Env_Value_0_Exists then Ada.Environment_Variables.Value ("GIT_CONFIG_VALUE_0") else "");
      Env_Key_1_Exists : constant Boolean :=
        Ada.Environment_Variables.Exists ("GIT_CONFIG_KEY_1");
      Env_Key_1_Value  : constant String :=
        (if Env_Key_1_Exists then Ada.Environment_Variables.Value ("GIT_CONFIG_KEY_1") else "");
      Env_Value_1_Exists : constant Boolean :=
        Ada.Environment_Variables.Exists ("GIT_CONFIG_VALUE_1");
      Env_Value_1_Value  : constant String :=
        (if Env_Value_1_Exists then Ada.Environment_Variables.Value ("GIT_CONFIG_VALUE_1") else "");

      function Upper (Value : String) return String is
         Result : String := Value;
      begin
         for I in Result'Range loop
            if Result (I) in 'a' .. 'z' then
               Result (I) :=
                 Character'Val
                   (Character'Pos (Result (I))
                    - Character'Pos ('a')
                    + Character'Pos ('A'));
            end if;
         end loop;

         return Result;
      end Upper;

      procedure Restore_Env is
      begin
         if Home_Exists then
            Ada.Environment_Variables.Set ("HOME", Home_Value);
         else
            Ada.Environment_Variables.Clear ("HOME");
         end if;

         if XDG_Exists then
            Ada.Environment_Variables.Set ("XDG_CONFIG_HOME", XDG_Value);
         else
            Ada.Environment_Variables.Clear ("XDG_CONFIG_HOME");
         end if;

         if System_Exists then
            Ada.Environment_Variables.Set ("GIT_CONFIG_SYSTEM", System_Value);
         else
            Ada.Environment_Variables.Clear ("GIT_CONFIG_SYSTEM");
         end if;

         if Global_Exists then
            Ada.Environment_Variables.Set ("GIT_CONFIG_GLOBAL", Global_Value);
         else
            Ada.Environment_Variables.Clear ("GIT_CONFIG_GLOBAL");
         end if;

         if No_System_Exists then
            Ada.Environment_Variables.Set ("GIT_CONFIG_NOSYSTEM", No_System_Value);
         else
            Ada.Environment_Variables.Clear ("GIT_CONFIG_NOSYSTEM");
         end if;

         if Env_Count_Exists then
            Ada.Environment_Variables.Set ("GIT_CONFIG_COUNT", Env_Count_Value);
         else
            Ada.Environment_Variables.Clear ("GIT_CONFIG_COUNT");
         end if;

         if Env_Key_0_Exists then
            Ada.Environment_Variables.Set ("GIT_CONFIG_KEY_0", Env_Key_0_Value);
         else
            Ada.Environment_Variables.Clear ("GIT_CONFIG_KEY_0");
         end if;

         if Env_Value_0_Exists then
            Ada.Environment_Variables.Set ("GIT_CONFIG_VALUE_0", Env_Value_0_Value);
         else
            Ada.Environment_Variables.Clear ("GIT_CONFIG_VALUE_0");
         end if;

         if Env_Key_1_Exists then
            Ada.Environment_Variables.Set ("GIT_CONFIG_KEY_1", Env_Key_1_Value);
         else
            Ada.Environment_Variables.Clear ("GIT_CONFIG_KEY_1");
         end if;

         if Env_Value_1_Exists then
            Ada.Environment_Variables.Set ("GIT_CONFIG_VALUE_1", Env_Value_1_Value);
         else
            Ada.Environment_Variables.Clear ("GIT_CONFIG_VALUE_1");
         end if;
      end Restore_Env;

      procedure Write_Config (Path : String; Ignore_Path : String) is
      begin
         Version.Test_Support.Write_Text_File
           (Path,
            "[core]" & Character'Val (10)
            & Character'Val (9)
            & "excludesFile = "
            & Character'Val (34)
            & Ignore_Path
            & Character'Val (34)
            & Character'Val (10));
      end Write_Config;

      procedure Write_Include_Config (Path : String; Include_Path : String) is
      begin
         Version.Test_Support.Write_Text_File
           (Path,
            "[include]" & Character'Val (10)
            & Character'Val (9)
            & "path = "
            & Character'Val (34)
            & Include_Path
            & Character'Val (34)
            & Character'Val (10));
      end Write_Include_Config;

      procedure Write_Include_If_Config
        (Path : String; Condition : String; Include_Path : String) is
      begin
         Version.Test_Support.Write_Text_File
           (Path,
            "[includeIf "
            & Character'Val (34)
            & Condition
            & Character'Val (34)
            & "]"
            & Character'Val (10)
            & Character'Val (9)
            & "path = "
            & Character'Val (34)
            & Include_Path
            & Character'Val (34)
            & Character'Val (10));
      end Write_Include_If_Config;

      procedure Set_Env_Config (Key : String; Value : String) is
      begin
         Ada.Environment_Variables.Set ("GIT_CONFIG_COUNT", "1");
         Ada.Environment_Variables.Set ("GIT_CONFIG_KEY_0", Key);
         Ada.Environment_Variables.Set ("GIT_CONFIG_VALUE_0", Value);
         Ada.Environment_Variables.Clear ("GIT_CONFIG_KEY_1");
         Ada.Environment_Variables.Clear ("GIT_CONFIG_VALUE_1");
      end Set_Env_Config;

      procedure Set_Env_Config
        (Key_0   : String;
         Value_0 : String;
         Key_1   : String;
         Value_1 : String)
      is
      begin
         Ada.Environment_Variables.Set ("GIT_CONFIG_COUNT", "2");
         Ada.Environment_Variables.Set ("GIT_CONFIG_KEY_0", Key_0);
         Ada.Environment_Variables.Set ("GIT_CONFIG_VALUE_0", Value_0);
         Ada.Environment_Variables.Set ("GIT_CONFIG_KEY_1", Key_1);
         Ada.Environment_Variables.Set ("GIT_CONFIG_VALUE_1", Value_1);
      end Set_Env_Config;

      procedure Check (Path : String; Expected : Boolean; Message : String) is
      begin
         Ada.Directories.Set_Directory (Root);
         declare
            Repo  : constant Version.Repository.Repository_Handle :=
              Version.Repository.Open;
            Rules : constant Version.Ignore.Ignore_Rules :=
              Version.Ignore.Load (Repo);
         begin
            Assert
              (Version.Ignore.Is_Ignored (Rules, Path, False) = Expected,
               Message);
            Assert
              (Version.Ignore.Is_Ignored (Rules, Path, False)
               = Git_Check_Ignored (Root, Path),
               Message & " should match git check-ignore");
         end;
         Ada.Directories.Set_Directory (Old_Dir);
      end Check;
   begin
      Init_Empty_Repo (Root);
      Version.Test_Support.Make_Directory (Home_Dir);
      Version.Test_Support.Make_Directory (XDG_Dir);
      Version.Test_Support.Make_Directory (XDG_Git_Dir);
      Version.Test_Support.Make_Directory (Empty_XDG_Home_Dir);
      Version.Test_Support.Make_Directory (Empty_XDG_Home_Config_Dir);
      Version.Test_Support.Make_Directory (Empty_XDG_Home_Git_Dir);

      Version.Test_Support.Write_Text_File
        (System_Ignore, "system-only.tmp" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (XDG_Ignore, "xdg-only.tmp" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Home_Ignore, "home-only.tmp" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Empty_XDG_Home_Ignore,
         "empty-xdg-home-only.tmp" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Env_Global_Ignore, "env-global-only.tmp" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Included_Ignore, "included-only.tmp" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Conditional_Ignore, "conditional-only.tmp" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Nonmatching_Ignore, "nonmatching-only.tmp" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Case_Insensitive_Ignore, "case-insensitive-only.tmp" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Onbranch_Ignore, "onbranch-only.tmp" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Onbranch_Glob_Ignore, "onbranch-glob-only.tmp" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Onbranch_Nonmatching_Ignore, "onbranch-nonmatching-only.tmp" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Env_Command_Ignore, "env-command-only.tmp" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Env_Include_Ignore, "env-include-only.tmp" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Env_Onbranch_Ignore, "env-onbranch-only.tmp" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Env_Onbranch_Nonmatching_Ignore,
         "env-onbranch-nonmatching-only.tmp" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Local_Included_Ignore, "local-included-only.tmp" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Local_Ignore, "local-only.tmp" & Character'Val (10));
      Write_Config (System_Config, System_Ignore);
      Write_Config (Version.Test_Support.Join (XDG_Git_Dir, "config"), XDG_Ignore);
      Write_Config (Version.Test_Support.Join (Home_Dir, ".gitconfig"), Home_Ignore);
      Write_Config
        (Version.Test_Support.Join (Empty_XDG_Home_Git_Dir, "config"),
         Empty_XDG_Home_Ignore);
      Write_Config (Env_Global_Config, Env_Global_Ignore);
      Write_Config (Included_Config, Included_Ignore);
      Write_Config (Conditional_Config, Conditional_Ignore);
      Write_Config (Nonmatching_Config, Nonmatching_Ignore);
      Write_Config (Case_Insensitive_Config, Case_Insensitive_Ignore);
      Write_Config (Onbranch_Config, Onbranch_Ignore);
      Write_Config (Onbranch_Glob_Config, Onbranch_Glob_Ignore);
      Write_Config (Onbranch_Nonmatching_Config, Onbranch_Nonmatching_Ignore);
      Write_Config (Env_Command_Config, Env_Command_Ignore);
      Write_Config (Env_Include_Config, Env_Include_Ignore);
      Write_Config (Env_Onbranch_Config, Env_Onbranch_Ignore);
      Write_Config (Env_Onbranch_Nonmatching_Config, Env_Onbranch_Nonmatching_Ignore);
      Write_Config (Local_Included_Config, Local_Included_Ignore);

      Ada.Environment_Variables.Set ("HOME", Home_Dir);
      Ada.Environment_Variables.Set ("XDG_CONFIG_HOME", XDG_Dir);
      Ada.Environment_Variables.Set ("GIT_CONFIG_SYSTEM", System_Config);
      Ada.Environment_Variables.Clear ("GIT_CONFIG_GLOBAL");
      Ada.Environment_Variables.Clear ("GIT_CONFIG_NOSYSTEM");
      Check ("home-only.tmp", True, "HOME .gitconfig should override XDG and system core excludesFile");
      Check ("xdg-only.tmp", False, "XDG core excludesFile should be replaced by HOME .gitconfig");
      Check ("system-only.tmp", False, "system core excludesFile should be replaced by global config");

      Ada.Environment_Variables.Set ("HOME", Empty_XDG_Home_Dir);
      Ada.Environment_Variables.Set ("XDG_CONFIG_HOME", "");
      Check ("empty-xdg-home-only.tmp", True,
             "empty XDG_CONFIG_HOME should fall back to HOME .config/git/config");
      Check ("home-only.tmp", False,
             "empty-XDG fallback should use the replacement HOME directory");
      Ada.Environment_Variables.Set ("HOME", Home_Dir);
      Ada.Environment_Variables.Set ("XDG_CONFIG_HOME", XDG_Dir);

      Ada.Environment_Variables.Set ("GIT_CONFIG_GLOBAL", Env_Global_Config);
      Check ("env-global-only.tmp", True, "GIT_CONFIG_GLOBAL should replace HOME and XDG global config");
      Check ("home-only.tmp", False, "GIT_CONFIG_GLOBAL should suppress HOME .gitconfig core excludesFile");

      Write_Include_Config (Env_Global_Config, "included-config");
      Check ("included-only.tmp", True,
             "included global config should provide core excludesFile");
      Check ("env-global-only.tmp", False,
             "included later core excludesFile should override earlier global value");

      Version.Test_Support.Write_Text_File
        (Env_Global_Config,
         "[include] # comment" & Character'Val (10)
         & Character'Val (9)
         & "path = "
         & Character'Val (34)
         & "included-config"
         & Character'Val (34)
         & Character'Val (10));
      Check ("included-only.tmp", True,
             "include section with trailing comment should provide core excludesFile");

      Write_Include_If_Config
        (Env_Global_Config, "gitdir:" & Root & "/", Conditional_Config);
      Check ("conditional-only.tmp", True,
             "matching includeIf gitdir should provide core excludesFile");

      Write_Include_If_Config
        (Env_Global_Config,
         "gitdir:" & Version.Test_Support.Join (Root, ".git"),
         Conditional_Config);
      Check ("conditional-only.tmp", True,
             "includeIf gitdir exact .git path should provide core excludesFile");

      Write_Include_If_Config
        (Env_Global_Config,
         "gitdir:" & Version.Test_Support.Join (Root, ".git") & "/",
         Nonmatching_Config);
      Check ("nonmatching-only.tmp", False,
             "includeIf gitdir exact .git path with trailing slash should not match");

      Version.Test_Support.Write_Text_File
        (Env_Global_Config,
         "[includeIf "
         & Character'Val (34)
         & "gitdir:" & Root & "/"
         & Character'Val (34)
         & "] ; comment"
         & Character'Val (10)
         & Character'Val (9)
         & "path = "
         & Character'Val (34)
         & "conditional-config"
         & Character'Val (34)
         & Character'Val (10));
      Check ("conditional-only.tmp", True,
             "includeIf section with trailing comment should provide core excludesFile");

      Write_Include_If_Config
        (Env_Global_Config,
         "gitdir:" & Version.Test_Support.Join (Root, "other") & "/",
         Nonmatching_Config);
      Check ("nonmatching-only.tmp", False,
             "non-matching includeIf gitdir should be ignored");

      Write_Include_If_Config
        (Env_Global_Config,
         "gitdir/i:" & Upper (Root) & "/",
         Case_Insensitive_Config);
      Check ("case-insensitive-only.tmp", True,
             "includeIf gitdir/i should compare gitdir paths case-insensitively");

      Ada.Directories.Set_Directory (Root);
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
      begin
         Version.Config.Set_Key
           (Repo, "remote.origin.url", "https://example.com/project.git");
      end;
      Ada.Directories.Set_Directory (Old_Dir);

      Write_Include_If_Config
        (Env_Global_Config,
         "hasconfig:remote.*.url:https://example.com/*.git",
         Conditional_Config);
      Check ("conditional-only.tmp", True,
             "matching includeIf hasconfig remote URL should provide core.excludesFile");

      Write_Include_If_Config
        (Env_Global_Config,
         "hasconfig:remote.*.url:https://other.example/*.git",
         Nonmatching_Config);
      Check ("nonmatching-only.tmp", False,
             "non-matching includeIf hasconfig remote URL should be ignored");

      Ada.Directories.Set_Directory (Root);
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
      begin
         Version.Config.Unset_Key (Repo, "remote.origin.url");
      end;
      Ada.Directories.Set_Directory (Old_Dir);

      Version.Test_Support.Write_Text_File
        (Env_Global_Config,
         "[include]" & Character'Val (10)
         & Character'Val (9)
         & "path = "
         & Character'Val (34)
         & "remote-url-config"
         & Character'Val (34)
         & Character'Val (10)
         & "[includeIf "
         & Character'Val (34)
         & "hasconfig:remote.*.url:https://example.com/*.git"
         & Character'Val (34)
         & "]"
         & Character'Val (10)
         & Character'Val (9)
         & "path = "
         & Character'Val (34)
         & "conditional-config"
         & Character'Val (34)
         & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "remote-url-config"),
         "[remote "
         & Character'Val (34)
         & "origin"
         & Character'Val (34)
         & "]"
         & Character'Val (10)
         & Character'Val (9)
         & "url = https://example.com/project.git"
         & Character'Val (10));
      Check ("conditional-only.tmp", True,
             "remote URL from included config should satisfy includeIf hasconfig");

      Version.Test_Support.Write_Text_File
        (Env_Global_Config,
         "[include]" & Character'Val (10)
         & Character'Val (9)
         & "path = "
         & Character'Val (34)
         & "remote-url-level1"
         & Character'Val (34)
         & Character'Val (10)
         & "[includeIf "
         & Character'Val (34)
         & "hasconfig:remote.*.url:https://example.com/*.git"
         & Character'Val (34)
         & "]"
         & Character'Val (10)
         & Character'Val (9)
         & "path = "
         & Character'Val (34)
         & "conditional-config"
         & Character'Val (34)
         & Character'Val (10));
      Write_Include_Config
        (Version.Test_Support.Join (Root, "remote-url-level1"),
         "remote-url-config");
      Check ("conditional-only.tmp", True,
             "remote URL from nested included config should satisfy includeIf hasconfig");

      Set_Env_Config ("remote.origin.url", "https://example.com/project.git");
      Write_Include_If_Config
        (Env_Global_Config,
         "hasconfig:remote.*.url:https://example.com/*.git",
         Conditional_Config);
      Check ("conditional-only.tmp", True,
             "GIT_CONFIG_COUNT remote URL should satisfy includeIf hasconfig");
      Ada.Environment_Variables.Clear ("GIT_CONFIG_COUNT");
      Ada.Environment_Variables.Clear ("GIT_CONFIG_KEY_0");
      Ada.Environment_Variables.Clear ("GIT_CONFIG_VALUE_0");

      Write_Include_If_Config
        (Env_Global_Config, "onbranch:main", Onbranch_Config);
      Check ("onbranch-only.tmp", True,
             "matching includeIf onbranch should provide core excludesFile");

      Write_Include_If_Config
        (Env_Global_Config, "onbranch:ma*", Onbranch_Glob_Config);
      Check ("onbranch-glob-only.tmp", True,
             "includeIf onbranch should support branch glob patterns");

      Write_Include_If_Config
        (Env_Global_Config, "onbranch:feature/*", Onbranch_Nonmatching_Config);
      Check ("onbranch-nonmatching-only.tmp", False,
             "non-matching includeIf onbranch should be ignored");

      Ada.Directories.Set_Directory (Root);
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
      begin
         Version.Config.Set_Key (Repo, "core.excludesFile", Local_Ignore);
      end;
      Ada.Directories.Set_Directory (Old_Dir);
      Check ("local-only.tmp", True, "local config should override global core excludesFile");
      Check ("env-global-only.tmp", False, "local core excludesFile should replace GIT_CONFIG_GLOBAL value");

      Set_Env_Config ("core.excludesFile", Env_Command_Ignore);
      Check ("env-command-only.tmp", True,
             "GIT_CONFIG_COUNT core.excludesFile should override local config");
      Check ("local-only.tmp", False,
             "GIT_CONFIG_COUNT core.excludesFile should replace local config value");

      Set_Env_Config
        ("core.excludesFile", Local_Ignore,
         "core.excludesFile", Env_Command_Ignore);
      Check ("env-command-only.tmp", True,
             "later GIT_CONFIG_COUNT core.excludesFile should override earlier value");
      Check ("local-only.tmp", False,
             "later GIT_CONFIG_COUNT core.excludesFile should replace earlier value");

      Set_Env_Config
        ("core.excludesFile",
         Character'Val (34) & Env_Command_Ignore & Character'Val (34));
      Check ("env-command-only.tmp", False,
             "quoted GIT_CONFIG_COUNT core.excludesFile should be treated as a literal path");

      Set_Env_Config ("include.path", "env-include-config");
      Check ("env-include-only.tmp", False,
             "relative GIT_CONFIG_COUNT include.path should not be loaded");

      Set_Env_Config ("include.path", Env_Include_Config);
      Check ("env-include-only.tmp", True,
             "GIT_CONFIG_COUNT include.path should provide core excludesFile");

      Set_Env_Config ("includeIf.onbranch:main.path", Env_Onbranch_Config);
      Check ("env-onbranch-only.tmp", True,
             "GIT_CONFIG_COUNT includeIf onbranch should provide core excludesFile");

      Set_Env_Config
        ("includeIf.onbranch:main.path",
         Character'Val (34) & Env_Onbranch_Config & Character'Val (34));
      Check ("env-onbranch-only.tmp", False,
             "quoted GIT_CONFIG_COUNT includeIf path should be treated as a literal path");

      Set_Env_Config ("includeIf.onbranch:main.path", "env-onbranch-config");
      Check ("env-onbranch-only.tmp", False,
             "relative GIT_CONFIG_COUNT includeIf path should not be loaded");

      --  git 2.54 evaluates a relative gitdir:./ condition from GIT_CONFIG env
      --  against the repository and applies the (absolute-path) include, so the
      --  excludesFile it names takes effect. version matches this.
      Set_Env_Config ("includeIf.gitdir:./.path", Env_Onbranch_Config);
      Check ("env-onbranch-only.tmp", True,
             "relative GIT_CONFIG_COUNT gitdir includeIf condition is applied");

      Set_Env_Config
        ("includeIf.onbranch:feature/*.path", Env_Onbranch_Nonmatching_Config);
      Check ("env-onbranch-nonmatching-only.tmp", False,
             "non-matching GIT_CONFIG_COUNT includeIf onbranch should be ignored");

      Ada.Environment_Variables.Clear ("GIT_CONFIG_COUNT");
      Ada.Environment_Variables.Clear ("GIT_CONFIG_KEY_0");
      Ada.Environment_Variables.Clear ("GIT_CONFIG_VALUE_0");
      Ada.Environment_Variables.Clear ("GIT_CONFIG_KEY_1");
      Ada.Environment_Variables.Clear ("GIT_CONFIG_VALUE_1");

      Ada.Environment_Variables.Set ("GIT_CONFIG_NOSYSTEM", "1");
      Ada.Environment_Variables.Clear ("GIT_CONFIG_GLOBAL");
      Version.Config.Unset_Key
        (Version.Repository.Open_Git_Dir
           (Version.Test_Support.Join (Root, ".git")),
         "core.excludesFile");
      Check ("home-only.tmp", True, "GIT_CONFIG_NOSYSTEM should still allow global config");

      Ada.Directories.Set_Directory (Root);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, ".git/config"),
         "[include]" & Character'Val (10)
         & Character'Val (9)
         & "path = "
         & Character'Val (34)
         & "../local-included-config"
         & Character'Val (34)
         & Character'Val (10));
      Ada.Directories.Set_Directory (Old_Dir);
      Check ("local-included-only.tmp", True,
             "included local config should provide core excludesFile");
      Check ("home-only.tmp", False,
             "included local core excludesFile should override global config");

      Restore_Env;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         if Ada.Directories.Current_Directory /= Old_Dir then
            Ada.Directories.Set_Directory (Old_Dir);
         end if;
         Restore_Env;
         raise;
   end Core_Excludes_File_Config_Stack;

   procedure Info_Exclude_Is_Loaded_Before_Gitignore
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Init_Empty_Repo (Root);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, ".git/info/exclude"),
         "*.local"
         & Character'Val (10)
         & "scratch.tmp"
         & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, ".gitignore"),
         "!keep.local" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "scratch.local"), "ignored");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "scratch.tmp"), "ignored");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "keep.local"), "visible");

      Ada.Directories.Set_Directory (Root);

      declare
         Repo  : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Rules : constant Version.Ignore.Ignore_Rules :=
           Version.Ignore.Load (Repo);
      begin
         Assert
           (Version.Ignore.Is_Ignored (Rules, "scratch.local", False),
            "info/exclude wildcard should ignore matching files");
         Assert
           (Version.Ignore.Is_Ignored (Rules, "scratch.tmp", False),
            "info/exclude literal should ignore matching files");
         Assert
           (not Version.Ignore.Is_Ignored (Rules, "keep.local", False),
            ".gitignore negation should override lower-precedence info/exclude");
         Assert
           (Version.Ignore.Is_Ignored (Rules, "scratch.local", False)
            = Git_Check_Ignored (Root, "scratch.local"),
            "info/exclude wildcard should match git check-ignore");
         Assert
           (Version.Ignore.Is_Ignored (Rules, "keep.local", False)
            = Git_Check_Ignored (Root, "keep.local"),
            "info/exclude negation precedence should match git check-ignore");
      end;

      declare
         Result : constant Version.Status.Status_Result :=
           Version.Status.Current_Status;
      begin
         Assert
           (not Has_Change
                  (Result.Untracked, "scratch.local", Version.Status.New_File),
            "status must omit untracked files ignored by info/exclude");
         Assert
           (not Has_Change
                  (Result.Untracked, "scratch.tmp", Version.Status.New_File),
            "status must omit literal info/exclude ignored files");
         Assert
           (Has_Change (Result.Untracked, "keep.local", Version.Status.New_File),
            "status must show files re-included by .gitignore negation");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Info_Exclude_Is_Loaded_Before_Gitignore;

   procedure Status_Omits_Ignored_Untracked
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Build   : constant String := Version.Test_Support.Join (Root, "build");
      Backslash_File : constant String := "literal\ignored.tmp";
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Init_Empty_Repo (Root);
      Version.Test_Support.Make_Directory (Build);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, ".gitignore"),
         "build/"
         & Character'Val (10)
         & "*.o"
         & Character'Val (10)
         & "literal\\ignored.tmp"
         & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Build, "generated.txt"), "generated");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "main.o"), "object");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "main.adb"),
         "procedure Main is begin null; end Main;");
      if Version.Platform.Current = Version.Platform.POSIX_Platform then
         Version.Test_Support.Write_Text_File
           (Version.Test_Support.Join (Root, Backslash_File), "ignored");
      end if;

      Ada.Directories.Set_Directory (Root);

      declare
         Result : constant Version.Status.Status_Result :=
           Version.Status.Current_Status;
      begin
         Assert
           (Has_Change
              (Result.Untracked, ".gitignore", Version.Status.New_File),
            "untracked .gitignore should remain visible");
         Assert
           (Has_Change (Result.Untracked, "main.adb", Version.Status.New_File),
            "ordinary untracked file should remain visible");
         Assert
           (not Has_Change
                  (Result.Untracked, "main.o", Version.Status.New_File),
            "ignored object file should be omitted from untracked status");
         Assert
           (not Has_Change
                  (Result.Untracked,
                   "build/generated.txt",
                   Version.Status.New_File),
            "ignored directory content should be omitted from untracked status");
         if Version.Platform.Current = Version.Platform.POSIX_Platform then
            Assert
              (Git_Check_Ignored (Root, Backslash_File),
               "git should ignore the literal backslash filename");
            Assert
              (not Has_Change
                     (Result.Untracked, Backslash_File, Version.Status.New_File),
               "status must omit ignored POSIX filenames containing backslash");
         end if;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Status_Omits_Ignored_Untracked;

   procedure Tracked_Ignored_File_Still_Reports_Modified
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Init_Empty_Repo (Root);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "config.local"),
         "tracked" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add config.local");
      Version.Git_Fixtures.Run (Root, "git commit -m tracked-config");

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, ".gitignore"),
         "config.local" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "config.local"),
         "changed" & Character'Val (10));

      Ada.Directories.Set_Directory (Root);

      declare
         Result : constant Version.Status.Status_Result :=
           Version.Status.Current_Status;
      begin
         Assert
           (Has_Change
              (Result.Changes, "config.local", Version.Status.Modified_File),
            "tracked ignored file must still report working-tree modification");
         Assert
           (not Has_Change
                  (Result.Untracked, "config.local", Version.Status.New_File),
            "tracked ignored file must not be treated as untracked");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Tracked_Ignored_File_Still_Reports_Modified;

   procedure Tracked_File_Under_Ignored_Directory_Still_Scanned
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Bin     : constant String := Version.Test_Support.Join (Root, "bin");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Init_Empty_Repo (Root);
      Version.Test_Support.Make_Directory (Bin);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, ".gitignore"),
         "bin/" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Bin, "tool.txt"),
         "tracked" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add -f .gitignore bin/tool.txt");
      Version.Git_Fixtures.Run (Root, "git commit -m tracked-bin-file");

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Bin, "tool.txt"),
         "changed" & Character'Val (10));

      Ada.Directories.Set_Directory (Root);

      declare
         Result : constant Version.Status.Status_Result :=
           Version.Status.Current_Status;
      begin
         Assert
           (Has_Change
              (Result.Changes, "bin/tool.txt", Version.Status.Modified_File),
            "tracked file below an ignored directory must be scanned and reported modified");
         Assert
           (not Has_Change
                  (Result.Changes,
                   "bin/tool.txt",
                   Version.Status.Deleted_File),
            "ignored-directory traversal must not make tracked files look deleted");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Tracked_File_Under_Ignored_Directory_Still_Scanned;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
   begin
      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Basic_Rule_Matching'Access,
         "Ignore: basic patterns, comments, directory rules, negation");
      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Slash_And_Nested_Rules'Access,
         "Ignore: slash patterns, nested gitignore, double-star");
      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Escaped_Slash_Rules_Match_Git'Access,
         "Ignore: escaped slash patterns match git check-ignore");
      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Double_Star_Rules_Match_Git'Access,
         "Ignore: double-star positions match git check-ignore");
      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Escaped_Prefixes_And_Trailing_Spaces'Access,
         "Ignore: escaped comment, negation, and trailing-space syntax");
      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         CRLF_Ignore_File_Matches_Git'Access,
         "Ignore: CRLF gitignore files match git check-ignore");
      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         UTF8_BOM_Ignore_File_Matches_Git'Access,
         "Ignore: UTF-8 BOM gitignore files match git check-ignore");
      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Symlinked_Gitignore_Files_Are_Not_Loaded'Access,
         "Ignore: symlinked gitignore files are not loaded");
      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Directory_Name_Rule_Ignores_Descendants'Access,
         "Ignore: directory basename descendants and git-internal protection");
      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Parent_Directory_Exclusion_Prevents_File_Reinclude'Access,
         "Ignore: ignored parent directories block child re-inclusion");
      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Directory_Only_Rule_Does_Not_Ignore_File'Access,
         "Ignore: directory-only rules do not match same-named files");
      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Core_Ignore_Case_Matches_Git'Access,
         "Ignore: core.ignoreCase matching matches git check-ignore");
      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Core_Ignore_Case_Config_Stack_Matches_Git'Access,
         "Ignore: core.ignoreCase config stack matches git check-ignore");
      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Dot_Segment_Query_Paths_Match_Git'Access,
         "Ignore: normalized query paths match git check-ignore");
      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Load_Relative_Root_Normalizes_Absolute_Queries'Access,
         "Ignore: relative Load root normalizes absolute queries");
      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Bracket_Character_Class_Rules'Access,
         "Ignore: bracket character classes and ranges");
      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Git_Check_Ignore_Core_Compatibility'Access,
         "Ignore: core cases match git check-ignore");
      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Core_Excludes_File_Is_Loaded_First'Access,
         "Ignore: core excludesFile loads below local excludes");
      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Core_Excludes_File_Path_Forms'Access,
         "Ignore: core excludesFile path forms");
      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Core_Excludes_File_Default_Path'Access,
         "Ignore: default global excludes file matches git");
      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Core_Excludes_File_Config_Stack'Access,
         "Ignore: core excludesFile config stack matches git");
      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Info_Exclude_Is_Loaded_Before_Gitignore'Access,
         "Ignore: info/exclude loads below .gitignore precedence");
      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Status_Omits_Ignored_Untracked'Access,
         "Ignore: status omits ignored untracked files");
      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Tracked_Ignored_File_Still_Reports_Modified'Access,
         "Ignore: tracked ignored file still reports modified");
      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Tracked_File_Under_Ignored_Directory_Still_Scanned'Access,
         "Ignore: tracked file under ignored directory is still scanned");
   end Register_Tests;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Ignore");
   end Name;

end Version.Ignore.Tests;
