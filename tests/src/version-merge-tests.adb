with Ada.IO_Exceptions;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

package body Version.Merge.Tests is

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

   LF : constant Character := ASCII.LF;

   procedure Binary_Detection_Uses_NUL
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Version.Merge.Is_Binary_Content ("abc" & Character'Val (0) & "def"),
         "NUL-containing content must be binary");

      Assert
        (not Version.Merge.Is_Binary_Content ("plain text" & Character'Val (10)),
         "ordinary text must not be binary");
   end Binary_Detection_Uses_NUL;

   procedure Conflict_Kind_Round_Trips
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Version.Merge.Conflict_Kind_Value
           (Version.Merge.Conflict_Kind_Image (Version.Merge.Content_Conflict))
         = Version.Merge.Content_Conflict,
         "content conflict kind must round-trip");

      Assert
        (Version.Merge.Conflict_Kind_Value
           (Version.Merge.Conflict_Kind_Image (Version.Merge.Binary_Conflict))
         = Version.Merge.Binary_Conflict,
         "binary conflict kind must round-trip");
   end Conflict_Kind_Round_Trips;

   procedure Unsafe_Paths_Are_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      begin
         Version.Merge.Require_Safe_Path ("../escape.txt");
         Assert (False, "path traversal must be rejected");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            null;
      end;

      begin
         Version.Merge.Require_Safe_Path (".git/config");
         Assert (False, ".git paths must be rejected");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            null;
      end;

      begin
         Version.Merge.Require_Safe_Path ("src/.git/config");
         Assert (False, "nested .git paths must be rejected");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            null;
      end;

      begin
         Version.Merge.Require_Safe_Path ("src//main.adb");
         Assert (False, "empty path segments must be rejected");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            null;
      end;

      Version.Merge.Require_Safe_Path ("src/main.adb");
   end Unsafe_Paths_Are_Rejected;

   procedure Merge_File_Matches_Git
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      use Ada.Strings.Unbounded;

      function Opts (Style : Conflict_Style := Conflict_Style_Merge)
        return Version.Merge.Merge_File_Options
      is (Ours_Label   => To_Unbounded_String ("a"),
          Base_Label   => To_Unbounded_String ("b"),
          Theirs_Label => To_Unbounded_String ("c"),
          Style        => Style,
          Favor        => Favor_None,
          Marker_Size  => 7,
          Algorithm    => Diff_Algorithm_Myers,
          Whitespace   => Whitespace_Strict,
          Simplify_No_Alnum => True);

      Merged    : Unbounded_String;
      Conflicts : Natural;
   begin
      --  Clean, non-overlapping merge (changes a line apart so they don't
      --  touch in base coordinates).
      Version.Merge.Merge_File
        ("l1" & LF & "O2" & LF & "l3" & LF & "l4" & LF & "l5" & LF,
         "l1" & LF & "l2" & LF & "l3" & LF & "l4" & LF & "l5" & LF,
         "l1" & LF & "l2" & LF & "l3" & LF & "T4" & LF & "l5" & LF,
         Opts, Merged, Conflicts);
      Assert (To_String (Merged) =
                "l1" & LF & "O2" & LF & "l3" & LF & "T4" & LF & "l5" & LF
              and then Conflicts = 0,
              "clean merge must combine both sides with no conflict");

      --  Simple conflict (both change l2), default markers.
      Version.Merge.Merge_File
        ("l1" & LF & "O2" & LF & "l3" & LF,
         "l1" & LF & "l2" & LF & "l3" & LF,
         "l1" & LF & "T2" & LF & "l3" & LF,
         Opts, Merged, Conflicts);
      Assert (To_String (Merged) =
                "l1" & LF & "<<<<<<< a" & LF & "O2" & LF & "=======" & LF
                & "T2" & LF & ">>>>>>> c" & LF & "l3" & LF
              and then Conflicts = 1,
              "conflict markers must match git");

      --  --diff3 adds the base section.
      Version.Merge.Merge_File
        ("l1" & LF & "O2" & LF & "l3" & LF,
         "l1" & LF & "l2" & LF & "l3" & LF,
         "l1" & LF & "T2" & LF & "l3" & LF,
         Opts (Conflict_Style_Diff3), Merged, Conflicts);
      Assert (To_String (Merged) =
                "l1" & LF & "<<<<<<< a" & LF & "O2" & LF & "||||||| b" & LF
                & "l2" & LF & "=======" & LF & "T2" & LF & ">>>>>>> c" & LF
                & "l3" & LF,
              "diff3 layout must match git");

      --  Two conflicts three common lines apart combine into one (default).
      Version.Merge.Merge_File
        ("OA" & LF & "c1" & LF & "c2" & LF & "c3" & LF & "OZ" & LF,
         "A" & LF & "c1" & LF & "c2" & LF & "c3" & LF & "Z" & LF,
         "TA" & LF & "c1" & LF & "c2" & LF & "c3" & LF & "TZ" & LF,
         Opts, Merged, Conflicts);
      Assert (Conflicts = 1,
              "conflicts 3 common lines apart must combine (got"
              & Conflicts'Image & ")");

      --  Conflict refinement (git's xdl_refine_conflicts): the two sides of a
      --  conflict are re-diffed against each other, so lines they agree on are
      --  pushed outside the markers.  An empty base is the add/add case.
      Version.Merge.Merge_File
        ("common1" & LF & "MAIN" & LF & "common2" & LF,
         "",
         "common1" & LF & "FEAT" & LF & "common2" & LF,
         Opts, Merged, Conflicts);
      Assert (To_String (Merged) =
                "common1" & LF & "<<<<<<< a" & LF & "MAIN" & LF
                & "=======" & LF & "FEAT" & LF & ">>>>>>> c" & LF
                & "common2" & LF
              and then Conflicts = 1,
              "add/add must refine to a line-level conflict, as git does");

      --  git parity: a change merges on its own only when at least one common
      --  line separates it from the other side's change.  Edits on adjacent
      --  lines conflict (and combine into one hunk, being <= 3 lines apart).
      Version.Merge.Merge_File
        ("O1" & LF & "l2" & LF & "l3" & LF,
         "l1" & LF & "l2" & LF & "l3" & LF,
         "l1" & LF & "T2" & LF & "l3" & LF,
         Opts, Merged, Conflicts);
      Assert (Conflicts = 1,
              "edits on adjacent lines must conflict, as git does (got"
              & Conflicts'Image & ")");

      --  git's is_cr_needed: in a CRLF file the markers themselves end CR/LF.
      declare
         CRLF : constant String := ASCII.CR & ASCII.LF;
      begin
         Version.Merge.Merge_File
           ("l1" & CRLF & "O2" & CRLF & "l3" & CRLF,
            "l1" & CRLF & "l2" & CRLF & "l3" & CRLF,
            "l1" & CRLF & "T2" & CRLF & "l3" & CRLF,
            Opts, Merged, Conflicts);
         Assert (To_String (Merged) =
                   "l1" & CRLF & "<<<<<<< a" & CRLF & "O2" & CRLF
                   & "=======" & CRLF & "T2" & CRLF & ">>>>>>> c" & CRLF
                   & "l3" & CRLF
                 and then Conflicts = 1,
                 "CRLF file must get CRLF conflict markers, as git does");
      end;

      --  ... and an LF file must not pick up any CR.
      Version.Merge.Merge_File
        ("l1" & LF & "O2" & LF & "l3" & LF,
         "l1" & LF & "l2" & LF & "l3" & LF,
         "l1" & LF & "T2" & LF & "l3" & LF,
         Opts, Merged, Conflicts);
      Assert (Index (Merged, String'(1 => ASCII.CR)) = 0,
              "LF file must keep LF-only markers");

      --  Repeated lines admit several equally minimal edit scripts, and the
      --  conflict lands in a different place depending on which one the diff
      --  picks.  version's own LCS chose one script here and git's xdiff
      --  another; the Myers port (xdl_do_diff) settles it git's way, which is
      --  what keeps the hunks -- and the rerere ids -- aligned with git.
      Version.Merge.Merge_File
        ("f" & LF & "e" & LF & "a" & LF & "H" & LF & "f" & LF & "f" & LF
         & "G" & LF & "a" & LF & "h" & LF & "e" & LF & "b" & LF & "c" & LF,
         "f" & LF & "e" & LF & "a" & LF & "a" & LF & "f" & LF & "f" & LF
         & "d" & LF & "a" & LF & "h" & LF & "e" & LF & "b" & LF & "e" & LF
         & "c" & LF,
         "E" & LF & "G" & LF & "a" & LF & "f" & LF & "d" & LF & "a" & LF
         & "h" & LF & "C" & LF & "e" & LF & "B" & LF & "b" & LF & "e" & LF
         & "c" & LF,
         Opts, Merged, Conflicts);
      Assert (To_String (Merged) =
                "E" & LF & "G" & LF & "a" & LF
                & "<<<<<<< a" & LF & "H" & LF & "f" & LF
                & "=======" & LF & ">>>>>>> c" & LF
                & "f" & LF & "G" & LF & "a" & LF & "h" & LF & "C" & LF
                & "e" & LF & "B" & LF & "b" & LF & "c" & LF
              and then Conflicts = 1,
              "edit script must match git's xdiff, not just be minimal");

      --  git's two merge levels.  merge-file (ZEALOUS_ALNUM) folds the lines
      --  between two conflicts into one conflict when none of them carries a
      --  letter or digit, however many there are; `git merge` (ZEALOUS) only
      --  folds gaps of at most three lines.
      declare
         Gap : constant String :=
           LF & "{" & LF & "}" & LF & LF & " " & LF;   --  5 non-alnum lines
         Ours   : constant String := "A1" & Gap & "D1" & LF;
         Basis  : constant String := "a" & Gap & "d" & LF;
         Theirs : constant String := "A2" & Gap & "D2" & LF;
         Merge_Level : Version.Merge.Merge_File_Options := Opts;
      begin
         Version.Merge.Merge_File (Ours, Basis, Theirs, Opts, Merged, Conflicts);
         Assert (Conflicts = 1,
                 "merge-file must fold a no-alnum gap into one conflict (got"
                 & Conflicts'Image & ")");

         Merge_Level.Simplify_No_Alnum := False;   --  what `git merge` uses
         Version.Merge.Merge_File
           (Ours, Basis, Theirs, Merge_Level, Merged, Conflicts);
         Assert (Conflicts = 2,
                 "merge must leave the two conflicts apart (got"
                 & Conflicts'Image & ")");
      end;

      --  Repeated lines admit several equally minimal edit scripts, and the
      --  conflict lands in a different place depending on which one the diff
      --  picks.  version's own LCS chose one script here and git's xdiff
      --  another; the Myers port (xdl_do_diff) settles it git's way, which is
      --  what keeps the hunks -- and the rerere ids -- aligned with git.
      Version.Merge.Merge_File
        ("f" & LF & "e" & LF & "a" & LF & "H" & LF & "f" & LF & "f" & LF
         & "G" & LF & "a" & LF & "h" & LF & "e" & LF & "b" & LF & "c" & LF,
         "f" & LF & "e" & LF & "a" & LF & "a" & LF & "f" & LF & "f" & LF
         & "d" & LF & "a" & LF & "h" & LF & "e" & LF & "b" & LF & "e" & LF
         & "c" & LF,
         "E" & LF & "G" & LF & "a" & LF & "f" & LF & "d" & LF & "a" & LF
         & "h" & LF & "C" & LF & "e" & LF & "B" & LF & "b" & LF & "e" & LF
         & "c" & LF,
         Opts, Merged, Conflicts);
      Assert (To_String (Merged) =
                "E" & LF & "G" & LF & "a" & LF
                & "<<<<<<< a" & LF & "H" & LF & "f" & LF
                & "=======" & LF & ">>>>>>> c" & LF
                & "f" & LF & "G" & LF & "a" & LF & "h" & LF & "C" & LF
                & "e" & LF & "B" & LF & "b" & LF & "c" & LF
              and then Conflicts = 1,
              "edit script must match git's xdiff, not just be minimal");

      --  git's two merge levels.  merge-file (ZEALOUS_ALNUM) folds the lines
      --  between two conflicts into one conflict when none of them carries a
      --  letter or digit, however many there are; `git merge` (ZEALOUS) only
      --  folds gaps of at most three lines.
      declare
         Gap : constant String :=
           LF & "{" & LF & "}" & LF & LF & " " & LF;   --  5 non-alnum lines
         Ours   : constant String := "A1" & Gap & "D1" & LF;
         Basis  : constant String := "a" & Gap & "d" & LF;
         Theirs : constant String := "A2" & Gap & "D2" & LF;
         Merge_Level : Version.Merge.Merge_File_Options := Opts;
      begin
         Version.Merge.Merge_File (Ours, Basis, Theirs, Opts, Merged, Conflicts);
         Assert (Conflicts = 1,
                 "merge-file must fold a no-alnum gap into one conflict (got"
                 & Conflicts'Image & ")");

         Merge_Level.Simplify_No_Alnum := False;   --  what `git merge` uses
         Version.Merge.Merge_File
           (Ours, Basis, Theirs, Merge_Level, Merged, Conflicts);
         Assert (Conflicts = 2,
                 "merge must leave the two conflicts apart (got"
                 & Conflicts'Image & ")");
      end;

      --  Whitespace folding decides *equality* only; the lines that get
      --  written out keep their original spacing.  (The "a whitespace-only
      --  side loses entirely" rule lives in the tree-merge path, not in
      --  Merge_File, and is covered by the branch tests -- `git merge-file`
      --  has no whitespace flags to compare against.)
      declare
         WS_Opts : Version.Merge.Merge_File_Options := Opts;
      begin
         WS_Opts.Whitespace := Whitespace_Ignore_Space_Change;
         Version.Merge.Merge_File
           ("a" & LF & "b  " & ASCII.HT & LF & "c" & LF & "D2" & LF & "e" & LF
            & "f" & LF & "g" & LF,
            "a" & LF & "b" & LF & "c" & LF & "d" & LF & "e" & LF & "f" & LF
            & "g" & LF,
            "a" & LF & "b" & LF & "c" & LF & "d" & LF & "e" & LF & "f" & LF
            & "G2" & LF,
            WS_Opts, Merged, Conflicts);
         Assert (To_String (Merged) =
                   "a" & LF & "b  " & ASCII.HT & LF & "c" & LF & "D2" & LF
                   & "e" & LF & "f" & LF & "G2" & LF
                 and then Conflicts = 0,
                 "folding must not rewrite the emitted line's whitespace");
      end;
   end Merge_File_Matches_Git;

   procedure Rerere_Conflict_Id_Matches_Git
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      --  A conflicted file whose sides (with labels, either order) reduce to
      --  the same git rerere id: SHA-1("FEAT\n\0MAIN\n\0").
      Conflict_A : constant String :=
        "a" & LF & "<<<<<<< main" & LF & "MAIN" & LF & "=======" & LF
        & "FEAT" & LF & ">>>>>>> feat" & LF & "c" & LF;
      Conflict_B : constant String :=
        "a" & LF & "<<<<<<< feat" & LF & "FEAT" & LF & "=======" & LF
        & "MAIN" & LF & ">>>>>>> main" & LF & "c" & LF;
      Expected : constant String :=
        "828b6ebae1471f9995f11753b4cdf87a0e566763";
   begin
      Assert (Version.Merge.Rerere_Conflict_Id (Conflict_A) = Expected,
              "rerere id must match git's rr-cache hash");
      Assert (Version.Merge.Rerere_Conflict_Id (Conflict_B) = Expected,
              "rerere id must be independent of conflict side order");
      Assert (Version.Merge.Rerere_Conflict_Id ("no conflict here" & LF) = "",
              "content without a conflict has no rerere id");
   end Rerere_Conflict_Id_Matches_Git;

   overriding procedure Register_Tests
     (T : in out Test_Case)
   is
   begin
      Register_Routine
        (T, Merge_File_Matches_Git'Access,
         "Merge: merge-file clean/conflict/diff3/combine match git");
      Register_Routine
        (T, Rerere_Conflict_Id_Matches_Git'Access,
         "Merge: rerere conflict id matches git's rr-cache hash");

      Register_Routine
        (T,
         Binary_Detection_Uses_NUL'Access,
         "Merge: binary detection uses NUL");

      Register_Routine
        (T,
         Conflict_Kind_Round_Trips'Access,
         "Merge: conflict kind image round-trips");

      Register_Routine
        (T,
         Unsafe_Paths_Are_Rejected'Access,
         "Merge: unsafe paths are rejected");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Merge");
   end Name;

end Version.Merge.Tests;
