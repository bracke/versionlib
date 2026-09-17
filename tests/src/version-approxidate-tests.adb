with AUnit.Assertions;    use AUnit.Assertions;
with AUnit.Test_Cases;

with Ada.Strings.Fixed;

with Version.Git_Fixtures;
with Version.Test_Support;
with Version.Timestamps;

package body Version.Approxidate.Tests is

   --  A fixed "now" -- 2026-09-17 20:44:16 UTC -- so the relative phrases
   --  have one answer; the absolute forms do not depend on it at all.
   Now : constant Long_Long_Integer := 1_789_678_656;

   procedure Check (Text : String; Want : Long_Long_Integer) is
      Got        : Long_Long_Integer;
      Recognized : Boolean;
   begin
      Version.Approxidate.Parse (Text, Got, Recognized, Now);
      Assert (Recognized, "approxidate '" & Text & "' not recognized");
      Assert
        (Got = Want,
         "approxidate '" & Text & "': got" & Got'Image & " want" & Want'Image);
   end Check;

   --  The forms whose value does not depend on the local zone.
   procedure Zone_Free_Forms_Parse
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Check ("@1704164645", 1_704_164_645);
      Check ("1704164645", 1_704_164_645);
      Check ("2024-01-02T03:04:05+0100", 1_704_161_045);
      Check ("2024-01-02 03:04:05 +0000", 1_704_164_645);
      Check ("2023-12-25T10:00:00Z", 1_703_498_400);
      Check ("Tue, 2 Jan 2024 03:04:05 +0100", 1_704_161_045);
      Check ("20240102T101112+0000", 1_704_190_272);
      Check ("2 weeks ago", Now - 14 * 86_400);
      Check ("2.weeks.ago", Now - 14 * 86_400);
      Check ("2 weeks", Now - 14 * 86_400);
      Check ("1 week 2 days ago", Now - 9 * 86_400);
      Check ("one week ago", Now - 7 * 86_400);
      Check ("five days ago", Now - 5 * 86_400);
      Check ("3 hours ago", Now - 3 * 3_600);
      Check ("60 minutes ago", Now - 3_600);
      Check ("30 seconds ago", Now - 30);
      Check ("0 days ago", Now);
      Check ("yesterday", Now - 86_400);
      Check ("now", Now);
      Check ("last week", Now - 7 * 86_400);
      Check ("never", 0);
   end Zone_Free_Forms_Parse;

   --  Garbage is "now" and flagged, as git's approxidate_careful reports.
   procedure Garbage_Is_Now_And_Unrecognized
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Got        : Long_Long_Integer;
      Recognized : Boolean;
   begin
      Version.Approxidate.Parse ("bogus", Got, Recognized, Now);
      Assert (not Recognized, "'bogus' must not be recognized");
      Assert (Got = Now, "'bogus' must answer now");
      Assert (Version.Approxidate.Value ("bogus", Now) = Now,
              "Value ('bogus') must answer now");
   end Garbage_Is_Now_And_Unrecognized;

   --  Oracle: `git commit --date=<text>` parses with the same engine, so
   --  the author date it records is the answer -- in whatever zone the
   --  test runs.  Relative phrases are compared against a NOW captured
   --  right before the commit (a second of slack for the clock).
   procedure Matches_Git_Commit_Date_Oracle
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Out_File : constant String :=
        Version.Test_Support.Join (Root, "oracle.out");
      Phrases : constant array (Positive range <>) of access constant String :=
        [new String'("2024-01-02"),
         new String'("Jan 2 2024"),
         new String'("2 Jan 2024"),
         new String'("01/02/2024"),
         new String'("2024.01.02"),
         new String'("25.12.2023"),
         new String'("2024-01-02 10:00"),
         new String'("Dec 25 2023 14:00"),
         new String'("10am"),
         new String'("3pm"),
         new String'("noon"),
         new String'("midnight"),
         new String'("today"),
         new String'("yesterday noon"),
         new String'("yesterday 10:00"),
         new String'("last friday"),
         new String'("3 months ago"),
         new String'("2 years ago"),
         new String'("january")];
   begin
      Version.Git_Fixtures.Run
        (Root, "git init -q && git config user.email a@b && git config user.name A");
      for P of Phrases loop
         declare
            Clock_Now : constant Long_Long_Integer := Version.Timestamps.Unix_Now;
            Got       : Long_Long_Integer;
            Recognized : Boolean;
         begin
            Version.Git_Fixtures.Run
              (Root,
               "git commit -q --allow-empty -m x --date='" & P.all
               & "' && git log -1 --format=%at > oracle.out");
            declare
               Want : constant Long_Long_Integer :=
                 Long_Long_Integer'Value
                   (Ada.Strings.Fixed.Trim
                      (Version.Test_Support.Read_Text_File (Out_File),
                       Ada.Strings.Both));
            begin
               Version.Approxidate.Parse (P.all, Got, Recognized, Clock_Now);
               Assert (Recognized, "'" & P.all & "' not recognized");
               Assert
                 (abs (Got - Want) <= 2,
                  "approxidate '" & P.all & "': got" & Got'Image
                  & " git" & Want'Image);
            end;
         end;
      end loop;
   end Matches_Git_Commit_Date_Oracle;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Zone_Free_Forms_Parse'Access,
         "Approxidate: unix, ISO, RFC 2822 and relative forms");
      Register_Routine
        (T, Garbage_Is_Now_And_Unrecognized'Access,
         "Approxidate: garbage is now, unrecognized");
      Register_Routine
        (T, Matches_Git_Commit_Date_Oracle'Access,
         "Approxidate: zone-dependent forms match git commit --date");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Approxidate");
   end Name;

end Version.Approxidate.Tests;
