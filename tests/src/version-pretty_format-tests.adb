with Ada.Directories;

with AUnit.Assertions;    use AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Files;
with Version.Git_Fixtures;
with Version.Init;
with Version.Objects;
with Version.Repository;
with Version.Revisions;
with Version.Test_Support;

package body Version.Pretty_Format.Tests is

   LF : constant Character := Character'Val (10);

   procedure Check
     (Repo   : Version.Repository.Repository_Handle;
      Id     : Version.Objects.Hex_Object_Id;
      Format : String;
      Want   : String)
   is
      Got : constant String := Version.Pretty_Format.Expand (Repo, Id, Format);
   begin
      Assert
        (Got = Want,
         "pretty '" & Format & "': got [" & Got & "] want [" & Want & "]");
   end Check;

   --  Byte oracle: Expand must equal `git log -1 --pretty=format:<Format>`
   --  exactly. Run writes git's raw stdout to a file we read back verbatim.
   procedure Check_Vs_Git
     (Root   : String;
      Repo   : Version.Repository.Repository_Handle;
      Id     : Version.Objects.Hex_Object_Id;
      Format : String)
   is
      Out_File : constant String :=
        Version.Test_Support.Join (Root, "pretty.out");
      Got : constant String := Version.Pretty_Format.Expand (Repo, Id, Format);
   begin
      Version.Git_Fixtures.Run
        (Root,
         "git log -1 --pretty=format:'" & Format & "' > pretty.out");
      declare
         Want : constant String := Version.Files.Read_Binary_File (Out_File);
      begin
         Assert (Got = Want,
                 "pretty '" & Format & "' vs git: got [" & Got
                 & "] git [" & Want & "]");
      end;
   end Check_Vs_Git;

   --  A commit with fixed identity/dates/message; every commit-object-derived
   --  placeholder is asserted against git's known output (captured offline with
   --  LANG=C, TZ=UTC, isolated config).
   procedure Expand_Matches_Git_Oracle
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email t@e.com");
      Version.Git_Fixtures.Run (Root, "git config user.name T");
      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "a.txt"), "root" & LF);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "msg.txt"),
         "The subject line here" & LF & LF
         & "Body paragraph one." & LF & LF
         & "Signed-off-by: Ada Lovelace <ada@example.com>" & LF
         & "Reviewed-by: Babbage <c@x.com>" & LF);
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Git_Fixtures.Run
        (Root,
         "GIT_AUTHOR_NAME='Ada Lovelace' GIT_AUTHOR_EMAIL='ada@example.com' "
         & "GIT_AUTHOR_DATE='2005-04-07T22:13:13 +0200' "
         & "GIT_COMMITTER_NAME='Charles Babbage' "
         & "GIT_COMMITTER_EMAIL='charles@EXAMPLE.com' "
         & "GIT_COMMITTER_DATE='2005-04-08T15:16:17 -0700' "
         & "git commit -q -F msg.txt");

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Id   : constant Version.Objects.Hex_Object_Id :=
           Version.Revisions.Resolve_Commit (Repo, "HEAD");
         Full : constant String := Version.Objects.To_String (Id);
      begin
         --  Hashes.
         Check (Repo, Id, "%H", Full);
         Check (Repo, Id, "%h", Full (Full'First .. Full'First + 6));
         --  Author identity + local part.
         Check (Repo, Id, "%an", "Ada Lovelace");
         Check (Repo, Id, "%ae", "ada@example.com");
         Check (Repo, Id, "%al", "ada");
         --  Committer identity (note the capitalised e-mail domain preserved).
         Check (Repo, Id, "%cn", "Charles Babbage");
         Check (Repo, Id, "%ce", "charles@EXAMPLE.com");
         Check (Repo, Id, "%cl", "charles");
         --  Author dates in every absolute format.
         Check (Repo, Id, "%ad", "Thu Apr 7 22:13:13 2005 +0200");
         Check (Repo, Id, "%aD", "Thu, 7 Apr 2005 22:13:13 +0200");
         Check (Repo, Id, "%ai", "2005-04-07 22:13:13 +0200");
         Check (Repo, Id, "%aI", "2005-04-07T22:13:13+02:00");
         Check (Repo, Id, "%as", "2005-04-07");
         Check (Repo, Id, "%at", "1112904793");
         --  Committer dates (negative offset).
         Check (Repo, Id, "%cd", "Fri Apr 8 15:16:17 2005 -0700");
         Check (Repo, Id, "%ci", "2005-04-08 15:16:17 -0700");
         Check (Repo, Id, "%cI", "2005-04-08T15:16:17-07:00");
         Check (Repo, Id, "%cs", "2005-04-08");
         Check (Repo, Id, "%ct", "1112998577");
         --  Message pieces.
         Check (Repo, Id, "%s", "The subject line here");
         Check (Repo, Id, "%f", "The-subject-line-here");
         --  git's %b/%B end with a single trailing newline.
         Check
           (Repo, Id, "%b",
            "Body paragraph one." & LF & LF
            & "Signed-off-by: Ada Lovelace <ada@example.com>" & LF
            & "Reviewed-by: Babbage <c@x.com>" & LF);
         Check
           (Repo, Id, "%B",
            "The subject line here" & LF & LF
            & "Body paragraph one." & LF & LF
            & "Signed-off-by: Ada Lovelace <ada@example.com>" & LF
            & "Reviewed-by: Babbage <c@x.com>" & LF);
         --  Byte-oracle the message placeholders directly against git.
         Check_Vs_Git (Root, Repo, Id, "%s");
         Check_Vs_Git (Root, Repo, Id, "%f");
         Check_Vs_Git (Root, Repo, Id, "%b");
         Check_Vs_Git (Root, Repo, Id, "%B");
         Check (Repo, Id, "%e", "");
         --  No parent on the root commit.
         Check (Repo, Id, "%P", "");
         Check (Repo, Id, "%p", "");
         --  Literal escapes and unknown-placeholder passthrough.
         Check (Repo, Id, "a%%b", "a%b");
         Check (Repo, Id, "x%ny", "x" & LF & "y");
         Check (Repo, Id, "%x41", "A");
         Check (Repo, Id, "%z", "%z");
         Check (Repo, Id, "%ac", "%ac");
         --  Decoration: the commit is the tip of the default branch, so %D is
         --  "HEAD -> <branch>" and %d is git's " (...)"-wrapped form.
         declare
            Bare : constant String :=
              Version.Pretty_Format.Expand (Repo, Id, "%D");
         begin
            Assert
              (Bare'Length >= 8
               and then Bare (Bare'First .. Bare'First + 7) = "HEAD -> ",
               "%D must start with 'HEAD -> ', got [" & Bare & "]");
            Check (Repo, Id, "%d", " (" & Bare & ")");
         end;
         --  Mixed literal + placeholder.
         Check (Repo, Id, "commit %h by %an", "commit "
            & Full (Full'First .. Full'First + 6) & " by Ada Lovelace");
         --  .mailmap rewrites %aN/%aE (uppercase) but not %an/%ae.
         Version.Test_Support.Write_Text_File
           (Version.Test_Support.Join (Root, ".mailmap"),
            "Augusta Ada King <ada.king@example.com> <ada@example.com>" & LF);
         Check (Repo, Id, "%aN", "Augusta Ada King");
         Check (Repo, Id, "%aE", "ada.king@example.com");
         Check (Repo, Id, "%an", "Ada Lovelace");
         Check (Repo, Id, "%ae", "ada@example.com");
         --  The body's last paragraph is a trailer block.
         Check
           (Repo, Id, "%(trailers)",
            "Signed-off-by: Ada Lovelace <ada@example.com>" & LF
            & "Reviewed-by: Babbage <c@x.com>" & LF);
         Check
           (Repo, Id, "%(trailers:key=Reviewed-by)",
            "Reviewed-by: Babbage <c@x.com>" & LF);
         Check
           (Repo, Id, "%(trailers:keyonly,separator=%x2C)",
            "Signed-off-by,Reviewed-by");
         --  The commit is unsigned: git's gpg placeholders.
         Check (Repo, Id, "%G?", "N");
         Check (Repo, Id, "%GS", "");
         Check (Repo, Id, "%GK", "");
         Check (Repo, Id, "%GG", "");
         Check (Repo, Id, "%GF", "");
         Check (Repo, Id, "%GP", "");
         Check (Repo, Id, "%GT", "undefined");
         --  Colour placeholders vanish without a colour context.
         Check (Repo, Id, "%CredZ%Creset", "Z");
         Check (Repo, Id, "%C(bold red)Z%C(reset)", "Z");
         --  Column alignment and truncation (author is "Ada Lovelace", 12).
         Check (Repo, Id, "%<(15)%an|", "Ada Lovelace   |");
         Check (Repo, Id, "%>(15)%an|", "   Ada Lovelace|");
         Check (Repo, Id, "%<(6,trunc)%an", "Ada ..");
         Check (Repo, Id, "%<(6,ltrunc)%an", "..lace");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Expand_Matches_Git_Oracle;

   --  %ar (relative date) buckets on a commit dated a fixed 100 days ago,
   --  which sits safely inside git's "months" bucket ((100+15)/30 = 3) so the
   --  result is stable regardless of when the suite runs.
   procedure Relative_Date_Buckets_Match_Git
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email t@e.com");
      Version.Git_Fixtures.Run (Root, "git config user.name T");
      Ada.Directories.Set_Directory (Root);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "a.txt"), "x" & LF);
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Git_Fixtures.Run
        (Root,
         "GIT_AUTHOR_DATE=""$(date -u -d '100 days ago' '+%Y-%m-%dT%H:%M:%S "
         & "+0000')"" GIT_COMMITTER_DATE=""$(date -u -d '100 days ago' "
         & "'+%Y-%m-%dT%H:%M:%S +0000')"" git commit -q -m past");
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Id   : constant Version.Objects.Hex_Object_Id :=
           Version.Revisions.Resolve_Commit (Repo, "HEAD");
      begin
         Check (Repo, Id, "%ar", "3 months ago");
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Relative_Date_Buckets_Match_Git;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Expand_Matches_Git_Oracle'Access,
         "Pretty_Format: commit-derived placeholders match git");
      Register_Routine
        (T, Relative_Date_Buckets_Match_Git'Access,
         "Pretty_Format: %ar relative-date bucket matches git");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Pretty_Format");
   end Name;

end Version.Pretty_Format.Tests;
