with Version.Objects;
with Ada.Directories; use Ada.Directories;
with Ada.Exceptions;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Files;
with Version.Git_Fixtures;
with Version.Test_Support;
with Version.Init;
with Version.Maintenance;
with Version.Repository;
with Version.Refs;
with Version.Revisions;
with Version.Write;

package body Version.Tags.Tests is
   use Version.Objects;

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

   procedure Create_List_Delete_Tag
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String :=
        Ada.Directories.Current_Directory;

      File_Path : constant String :=
        Version.Test_Support.Join (Root, "a.txt");
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");

      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (File_Path,
         "one" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("initial");

      Version.Tags.Create_Tag ("v1.0");

      declare
         Tag_Tip : constant String := To_String (Version.Tags.Resolve_Tag ("v1.0"));
         Raised  : Boolean := False;
      begin
         begin
            Version.Tags.Create_Tag ("v1.0");
         exception
            when E : Ada.IO_Exceptions.Data_Error =>
               Raised := True;
               Assert
                 (Ada.Exceptions.Exception_Message (E)
                  = Version.Tags.Tag_Already_Exists_Diagnostic ("v1.0"),
                  "duplicate tag diagnostic changed: "
                  & Ada.Exceptions.Exception_Message (E));
         end;

         Assert (Raised, "duplicate tag create must be rejected");
         Assert
           (To_String (Version.Tags.Resolve_Tag ("v1.0")) = Tag_Tip,
            "duplicate tag create must preserve existing ref");
      end;

      declare
         Tags : constant Version.Tags.Tag_Name_Vectors.Vector :=
           Version.Tags.List_Tags;
      begin
         Assert
           (Natural (Tags.Length) = 1,
            "tag list must contain created tag");

         Assert
           (Ada.Strings.Unbounded.To_String (Tags.Element (Tags.First_Index)) = "v1.0",
            "tag name mismatch");
      end;

      Version.Git_Fixtures.Run
        (Root,
         "test ""$(git rev-parse v1.0)"" = ""$(git rev-parse HEAD)""");

      declare
         Repo     : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Expected : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         --  git: "Deleted tag 'v1.0' (was <abbrev>)"; a repo this small
         --  abbreviates at the 7-character floor.
         Assert
           (Version.Tags.Delete_Tag_Text ("v1.0")
            = "Deleted tag 'v1.0' (was "
              & Expected (Expected'First .. Expected'First + 6) & ")",
            "tag delete text must match git's report line");
      end;

      declare
         Tags : constant Version.Tags.Tag_Name_Vectors.Vector :=
           Version.Tags.List_Tags;
      begin
         Assert
           (Tags.Is_Empty,
            "tag list must be empty after delete");
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Create_List_Delete_Tag;

   procedure Create_Tag_Rejects_Existing_Lock
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String :=
        Ada.Directories.Current_Directory;

      File_Path : constant String :=
        Version.Test_Support.Join (Root, "a.txt");
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");

      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (File_Path,
         "one" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("initial");

      declare
         Lock_Path : constant String :=
           Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join
                   (Root, ".git"),
                 "refs/tags"),
              "v1.0.lock");
         Raised    : Boolean := False;
      begin
         Version.Test_Support.Write_Text_File
           (Lock_Path, "locked" & Character'Val (10));

         begin
            Version.Tags.Create_Tag ("v1.0");
         exception
            when E : Ada.IO_Exceptions.Data_Error =>
               Raised := True;
               Assert
                 (Ada.Exceptions.Exception_Message (E)
                  = Version.Tags.Tag_Already_Exists_Diagnostic ("v1.0")
                  or else Ada.Strings.Fixed.Index
                    (Ada.Exceptions.Exception_Message (E),
                     "lock file already exists:") /= 0,
                  "tag lock diagnostic changed: "
                  & Ada.Exceptions.Exception_Message (E));
         end;

         Version.Files.Delete_File_If_Exists (Lock_Path);

         Assert (Raised, "tag create must reject an existing lock file");
         Assert
           (not Version.Tags.Tag_Exists ("v1.0"),
            "failed tag create must not leave a tag ref");
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Create_Tag_Rejects_Existing_Lock;

   procedure Create_List_Delete_Nested_Tag
   (T : in out AUnit.Test_Cases.Test_Case'Class) is
      Root : constant String :=
      Version.Temp_Fixture.Root
         (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String :=
      Ada.Directories.Current_Directory;

      File_Path : constant String :=
      Version.Test_Support.Join (Root, "a.txt");

      function Contains_Tag
      (Tags : Version.Tags.Tag_Name_Vectors.Vector;
         Name : String)
         return Boolean
      is
      begin
         if Tags.Is_Empty then
            return False;
         end if;

         for I in Tags.First_Index .. Tags.Last_Index loop
            if Ada.Strings.Unbounded.To_String (Tags.Element (I)) = Name then
               return True;
            end if;
         end loop;

         return False;
      end Contains_Tag;

   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");

      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
      (File_Path,
         "one" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("initial");

      Version.Tags.Create_Tag ("release/v1.0");

      declare
         Tags : constant Version.Tags.Tag_Name_Vectors.Vector :=
         Version.Tags.List_Tags;
      begin
         Assert
         (Contains_Tag (Tags, "release/v1.0"),
            "tag list must contain nested tag");
      end;

      Version.Git_Fixtures.Run
      (Root,
         "test ""$(git rev-parse release/v1.0)"" = ""$(git rev-parse HEAD)""");

      Version.Tags.Delete_Tag ("release/v1.0");

      declare
         Tags : constant Version.Tags.Tag_Name_Vectors.Vector :=
         Version.Tags.List_Tags;
      begin
         Assert
         (not Contains_Tag (Tags, "release/v1.0"),
            "nested tag list must not contain deleted tag");
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Create_List_Delete_Nested_Tag;

   procedure Rename_Tag_Preserves_Target_And_Fails_Safely
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String :=
        Ada.Directories.Current_Directory;

      File_Path : constant String :=
        Version.Test_Support.Join (Root, "a.txt");

      Duplicate_Raised : Boolean := False;
      Missing_Raised   : Boolean := False;
      Invalid_Raised   : Boolean := False;
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");

      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (File_Path,
         "one" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("initial");

      Version.Tags.Create_Annotated_Tag ("old", "annotated release");
      Version.Tags.Create_Tag ("taken");

      declare
         Old_Id : constant String := To_String (Version.Tags.Resolve_Tag ("old"));
      begin
         Assert
           (Version.Tags.Rename_Tag_Text ("old", "new")
            = "renamed tag old new " & Old_Id,
            "tag rename text must include moved object id");
         Assert
           (not Version.Tags.Tag_Exists ("old"),
            "tag rename must remove old tag ref");
         Assert
           (To_String (Version.Tags.Resolve_Tag ("new")) = Old_Id,
            "tag rename must preserve target object id");
      end;

      Version.Git_Fixtures.Run (Root, "git pack-refs --all --prune");

      declare
         Packed_Id : constant String := To_String (Version.Tags.Resolve_Tag ("new"));
      begin
         Assert
           (Version.Tags.Rename_Tag_Text ("new", "packed-new")
            = "renamed tag new packed-new " & Packed_Id,
            "packed tag rename text must include moved object id");
         Assert
           (not Version.Tags.Tag_Exists ("new"),
            "packed tag rename must remove old packed ref");
         Assert
           (To_String (Version.Tags.Resolve_Tag ("packed-new")) = Packed_Id,
            "packed tag rename must preserve target object id");
      end;

      begin
         Version.Tags.Rename_Tag ("packed-new", "taken");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Duplicate_Raised := True;
      end;

      Assert (Duplicate_Raised, "tag rename must reject duplicate destination");
      Assert
        (Version.Tags.Tag_Exists ("packed-new")
         and then Version.Tags.Tag_Exists ("taken"),
         "duplicate rename must not mutate tags");

      begin
         Version.Tags.Rename_Tag ("missing", "other");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Missing_Raised := True;
      end;

      Assert (Missing_Raised, "tag rename must reject missing source");
      Assert
        (not Version.Tags.Tag_Exists ("other"),
         "missing-source rename must not create destination");

      begin
         Version.Tags.Rename_Tag ("packed-new", "bad..name");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Invalid_Raised := True;
      end;

      Assert (Invalid_Raised, "tag rename must reject invalid destination");
      Assert
        (Version.Tags.Tag_Exists ("packed-new"),
         "invalid-destination rename must preserve source");

      Version.Tags.Create_Tag ("rollback-source");
      Version.Git_Fixtures.Run (Root, "git pack-refs --all --prune");

      declare
         Rollback_Id : constant String :=
           To_String (Version.Tags.Resolve_Tag ("rollback-source"));
         Lock_Path   : constant String :=
           Version.Test_Support.Join
             (Version.Test_Support.Join (Root, ".git"), "packed-refs.lock");
         Raised      : Boolean := False;
      begin
         Version.Test_Support.Write_Text_File
           (Lock_Path,
            "locked" & Character'Val (10));

         begin
            Version.Tags.Rename_Tag ("rollback-source", "rollback-target");
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;

         Version.Files.Delete_File_If_Exists (Lock_Path);

         Assert (Raised, "tag rename must report source delete failure");
         Assert
           (Version.Tags.Tag_Exists ("rollback-source"),
            "failed rename must preserve source tag");
         Assert
           (not Version.Tags.Tag_Exists ("rollback-target"),
            "failed rename must remove partial destination tag");
         Assert
           (To_String (Version.Tags.Resolve_Tag ("rollback-source")) = Rollback_Id,
            "failed rename must preserve source object id");
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Rename_Tag_Preserves_Target_And_Fails_Safely;

   procedure List_Packed_Tags
   (T : in out AUnit.Test_Cases.Test_Case'Class) is
      Root : constant String :=
      Version.Temp_Fixture.Root
         (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String :=
      Ada.Directories.Current_Directory;

      File_Path : constant String :=
      Version.Test_Support.Join (Root, "a.txt");

      function Contains_Tag
      (Tags : Version.Tags.Tag_Name_Vectors.Vector;
         Name : String)
         return Boolean
      is
      begin
         if Tags.Is_Empty then
            return False;
         end if;

         for I in Tags.First_Index .. Tags.Last_Index loop
            if Ada.Strings.Unbounded.To_String (Tags.Element (I)) = Name then
               return True;
            end if;
         end loop;

         return False;
      end Contains_Tag;

   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");

      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
      (File_Path,
         "one" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("initial");

      Version.Tags.Create_Tag ("release/v1.0");

      Version.Git_Fixtures.Run (Root, "git pack-refs --all --prune");

      declare
         Tags : constant Version.Tags.Tag_Name_Vectors.Vector :=
         Version.Tags.List_Tags;
      begin
         Assert
         (Contains_Tag (Tags, "release/v1.0"),
            "tag list must contain packed tag");
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end List_Packed_Tags;

   procedure List_Tags_Is_Deterministic
   (T : in out AUnit.Test_Cases.Test_Case'Class) is
      Root : constant String :=
      Version.Temp_Fixture.Root
         (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String :=
      Ada.Directories.Current_Directory;

      File_Path : constant String :=
      Version.Test_Support.Join (Root, "a.txt");
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");

      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
      (File_Path,
         "one" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("initial");

      Version.Tags.Create_Tag ("zeta");
      Version.Tags.Create_Tag ("alpha");
      Version.Tags.Create_Tag ("release/beta");

      declare
         Tags : constant Version.Tags.Tag_Name_Vectors.Vector :=
         Version.Tags.List_Tags;
      begin
         Assert
         (Natural (Tags.Length) = 3,
            "tag list must contain all created tags");

         Assert
         (Ada.Strings.Unbounded.To_String (Tags.Element (Tags.First_Index)) = "alpha",
            "tag list must be sorted deterministically");

         Assert
         (Ada.Strings.Unbounded.To_String (Tags.Element (Tags.First_Index + 1)) = "release/beta",
            "nested tag must sort by full tag name");

         Assert
         (Ada.Strings.Unbounded.To_String (Tags.Element (Tags.First_Index + 2)) = "zeta",
            "last tag must be sorted deterministically");
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end List_Tags_Is_Deterministic;

   procedure List_Tags_Omits_Malformed_Loose_Refs
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String :=
        Ada.Directories.Current_Directory;

      File_Path : constant String :=
        Version.Test_Support.Join (Root, "a.txt");

      Broken_Ref : constant String :=
        Version.Test_Support.Join (Root, ".git/refs/tags/broken");

      function Contains_Tag
        (Tags : Version.Tags.Tag_Name_Vectors.Vector;
         Name : String)
         return Boolean
      is
      begin
         if Tags.Is_Empty then
            return False;
         end if;

         for I in Tags.First_Index .. Tags.Last_Index loop
            if Ada.Strings.Unbounded.To_String (Tags.Element (I)) = Name then
               return True;
            end if;
         end loop;

         return False;
      end Contains_Tag;
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");

      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (File_Path,
         "one" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("initial");

      Version.Tags.Create_Tag ("v1.0");
      Version.Tags.Create_Tag ("release/v1.0");
      Version.Test_Support.Write_Text_File (Broken_Ref, "not-an-object-id");

      declare
         Tags : constant Version.Tags.Tag_Name_Vectors.Vector :=
           Version.Tags.List_Tags;
      begin
         Assert
           (Contains_Tag (Tags, "v1.0"),
            "tag list must include valid loose tags");
         Assert
           (Contains_Tag (Tags, "release/v1.0"),
            "tag list must include valid nested loose tags");
         Assert
           (not Contains_Tag (Tags, "broken"),
            "tag list must omit malformed loose tag refs");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert
        (Version.Test_Support.Read_Text_File (Broken_Ref) = "not-an-object-id",
         "tag list must not rewrite malformed loose tag refs");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end List_Tags_Omits_Malformed_Loose_Refs;

   procedure Resolve_Loose_Tag
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String :=
        Ada.Directories.Current_Directory;

      File_Path : constant String :=
        Version.Test_Support.Join (Root, "a.txt");
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");

      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (File_Path,
         "one" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("initial");

      Version.Tags.Create_Tag ("v1.0");

      declare
         Repo     : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Expected : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         Assert
           (To_String (Version.Tags.Resolve_Tag ("v1.0")) = Expected,
            "tag resolve must return the tagged object id");

         Assert
           (Version.Tags.Resolve_Tag_Text ("v1.0") = Expected & Character'Val (10),
            "tag resolve text must be object id plus newline");

         Assert
           (To_String (Version.Tags.Peel_Tag ("v1.0")) = Expected,
            "lightweight tag peel must return the stored object id");

         Assert
           (Version.Tags.Peel_Tag_Text ("v1.0") = Expected & Character'Val (10),
            "tag peel text must be peeled object id plus newline");
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Resolve_Loose_Tag;

   procedure Create_Annotated_Tag
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String :=
        Ada.Directories.Current_Directory;

      File_Path : constant String :=
        Version.Test_Support.Join (Root, "a.txt");
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");

      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (File_Path,
         "one" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("initial");
      Version.Tags.Create_Annotated_Tag ("v1.0", "annotated release");

      declare
         Repo      : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Commit_Id : constant String := Version.Refs.Current_Commit_Id (Repo);
         Tag_Id    : constant String := To_String (Version.Tags.Resolve_Tag ("v1.0"));
         Repack    : Version.Maintenance.Maintenance_Result;
         pragma Unreferenced (Repack);
      begin
         Assert (Tag_Id /= Commit_Id, "annotated tag ref must point at a tag object");

         Version.Git_Fixtures.Run (Root, "test ""$(git cat-file -t v1.0)"" = tag");
         Version.Git_Fixtures.Run
           (Root,
            "test ""$(git rev-parse v1.0^{})"" = ""$(git rev-parse HEAD)""");
         Version.Git_Fixtures.Run
           (Root,
            "git tag --points-at HEAD | grep '^v1.0$'");

         Repack := Version.Maintenance.Repack (Repo);
         Version.Git_Fixtures.Run (Root, "git cat-file -t v1.0 >/dev/null");
         Assert
           (To_String (Version.Revisions.Resolve_Commit (Repo, "v1.0^{}")) = Commit_Id,
            "packed annotated tag must still peel to its commit");
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Create_Annotated_Tag;

   procedure Create_Tag_At_Explicit_Revision
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String :=
        Ada.Directories.Current_Directory;

      File_Path : constant String :=
        Version.Test_Support.Join (Root, "a.txt");

      Initial_Id  : String (1 .. 40);
      Second_Id   : String (1 .. 40);
      Raised      : Boolean := False;
      Duplicate   : Boolean := False;
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");

      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (File_Path,
         "one" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("initial");

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
      begin
         Initial_Id := Version.Refs.Current_Commit_Id (Repo);
      end;

      Version.Test_Support.Write_Text_File
        (File_Path,
         "two" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("second");

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
      begin
         Second_Id := Version.Refs.Current_Commit_Id (Repo);
      end;

      Version.Tags.Create_Tag
        (Name     => "v1.0",
         Revision => Initial_Id);
      Version.Tags.Create_Annotated_Tag
        (Name     => "v1.0-ann",
         Revision => Initial_Id,
         Message  => "annotated initial");

      Assert
        (To_String (Version.Tags.Resolve_Tag ("v1.0")) = Initial_Id,
         "explicit lightweight tag must point at selected revision");
      Assert
        (Version.Tags.List_Tags_Points_At_Text (Initial_Id)
         = "v1.0" & Character'Val (10)
         & "v1.0-ann" & Character'Val (10),
         "explicit annotated tag must peel to selected revision");
      Assert
        (Version.Tags.List_Tags_Points_At_Text (Second_Id) = "",
         "explicit target tags must not default to HEAD");
      begin
         Version.Tags.Create_Tag
           (Name     => "missing-target",
            Revision => "missing-revision");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "explicit tag create must reject missing revisions");

      begin
         Version.Tags.Create_Tag
           (Name     => "v1.0",
            Revision => Initial_Id);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Duplicate := True;
      end;

      Assert (Duplicate, "explicit tag create must reject duplicate tags");
      Assert
        (Natural (Version.Tags.List_Tags.Length) = 2,
         "failed explicit tag creates must not mutate tags");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Create_Tag_At_Explicit_Revision;

   procedure Resolve_Annotated_Tag
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String :=
        Ada.Directories.Current_Directory;

      File_Path : constant String :=
        Version.Test_Support.Join (Root, "a.txt");
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");

      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (File_Path,
         "one" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("initial");
      Version.Git_Fixtures.Run (Root, "git tag -a -m 'annotated release' v1.0");

      declare
         Repo     : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Commit_Id : constant String := Version.Refs.Current_Commit_Id (Repo);
         Raw_Tag   : constant String := To_String (Version.Tags.Resolve_Tag ("v1.0"));
         Peeled    : constant String :=
           To_String (Version.Revisions.Resolve_Commit (Repo, "v1.0^{}"));
         Points_At : constant String :=
           Version.Tags.List_Tags_Points_At_Text (Commit_Id);
      begin
         Assert
           (Raw_Tag /= Commit_Id,
            "annotated tag resolve must return the tag object id, not the commit id");

         Assert
           (Peeled = Commit_Id,
            "annotated tag peel must resolve to the tagged commit");

         Assert
           (To_String (Version.Tags.Peel_Tag ("v1.0")) = Commit_Id,
            "annotated tag peel command helper must return the tagged commit");

         Assert
           (Version.Tags.Peel_Tag_Text ("v1.0") = Commit_Id & Character'Val (10),
            "annotated tag peel text must be peeled id plus newline");

         Assert
           (Points_At = "v1.0" & Character'Val (10),
            "annotated tags must be included by points-at on the tagged commit");
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Resolve_Annotated_Tag;

   procedure Resolve_Packed_Tag
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String :=
        Ada.Directories.Current_Directory;

      File_Path : constant String :=
        Version.Test_Support.Join (Root, "a.txt");
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");

      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (File_Path,
         "one" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("initial");

      Version.Tags.Create_Tag ("release/v1.0");
      Version.Git_Fixtures.Run (Root, "git pack-refs --all --prune");

      declare
         Repo     : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Expected : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         Assert
           (To_String (Version.Tags.Resolve_Tag ("release/v1.0")) = Expected,
            "tag resolve must read packed tags");

         Assert
           (To_String (Version.Tags.Peel_Tag ("release/v1.0")) = Expected,
            "tag peel must read packed tags");
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Resolve_Packed_Tag;

   procedure Resolve_Missing_Tag_Fails
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String :=
        Ada.Directories.Current_Directory;

      Raised : Boolean := False;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);

      begin
         declare
            Ignored : constant String := Version.Tags.Peel_Tag_Text ("missing");
            pragma Unreferenced (Ignored);
         begin
            null;
         end;
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "missing tag peel must raise Data_Error");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Resolve_Missing_Tag_Fails;

   procedure Tag_Exists_Is_Quiet_Predicate_And_Read_Only
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String :=
        Ada.Directories.Current_Directory;

      File_Path : constant String :=
        Version.Test_Support.Join (Root, "a.txt");

      Raised : Boolean := False;

      function Contains_Tag
        (Tags : Version.Tags.Tag_Name_Vectors.Vector;
         Name : String)
         return Boolean
      is
      begin
         if Tags.Is_Empty then
            return False;
         end if;

         for I in Tags.First_Index .. Tags.Last_Index loop
            if Ada.Strings.Unbounded.To_String (Tags.Element (I)) = Name then
               return True;
            end if;
         end loop;

         return False;
      end Contains_Tag;

   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");

      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (File_Path,
         "one" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("initial");

      Version.Tags.Create_Tag ("v1.0");
      Version.Tags.Create_Tag ("release/v1.0");
      Version.Git_Fixtures.Run (Root, "git pack-refs --all --prune");

      Assert
        (Version.Tags.Tag_Exists ("v1.0"),
         "tag exists must return True for an existing tag");

      Assert
        (Version.Tags.Tag_Exists ("release/v1.0"),
         "tag exists must return True for a packed nested tag");

      Assert
        (not Version.Tags.Tag_Exists ("missing"),
         "tag exists must return False for a missing tag");

      begin
         declare
            Ignored : constant Boolean := Version.Tags.Tag_Exists ("bad..name");
            pragma Unreferenced (Ignored);
         begin
            null;
         end;
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert
        (Raised,
         "tag exists must reject invalid tag names through the normal validation path");

      declare
         Tags : constant Version.Tags.Tag_Name_Vectors.Vector :=
           Version.Tags.List_Tags;
      begin
         Assert
           (Natural (Tags.Length) = 2,
            "tag exists must not create or delete tags");

         Assert
           (Contains_Tag (Tags, "v1.0")
            and then Contains_Tag (Tags, "release/v1.0"),
            "tag exists must preserve existing tag refs");
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Tag_Exists_Is_Quiet_Predicate_And_Read_Only;

   procedure Tag_Exists_Returns_False_For_Malformed_Loose_Ref
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String :=
        Ada.Directories.Current_Directory;

      Ref_Path : constant String :=
        Version.Test_Support.Join (Root, ".git/refs/tags/broken");
   begin
      Version.Init.Init (Root);
      Version.Files.Create_Parent_Directories (Ref_Path);
      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File (Ref_Path, "not-an-object-id");

      Assert
        (not Version.Tags.Tag_Exists ("broken"),
         "tag exists must return false for malformed loose tag refs");
      Assert
        (Version.Test_Support.Read_Text_File (Ref_Path) = "not-an-object-id",
         "tag exists must not rewrite malformed loose tag refs");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Tag_Exists_Returns_False_For_Malformed_Loose_Ref;

   procedure List_Tags_Points_At_Revision
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String :=
        Ada.Directories.Current_Directory;

      File_Path : constant String :=
        Version.Test_Support.Join (Root, "a.txt");

      Broken_Ref : constant String :=
        Version.Test_Support.Join (Root, ".git/refs/tags/broken");

      Initial_Id : String (1 .. 40);
      Second_Id  : String (1 .. 40);
      Raised     : Boolean := False;
      Contains_Raised : Boolean := False;
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");

      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (File_Path,
         "one" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("initial");

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
      begin
         Initial_Id := Version.Refs.Current_Commit_Id (Repo);
      end;

      Version.Tags.Create_Tag ("v1.0");
      Version.Tags.Create_Tag ("release/v1.0");
      Version.Git_Fixtures.Run (Root, "git pack-refs --all --prune");
      Version.Test_Support.Write_Text_File (Broken_Ref, "not-an-object-id");

      Version.Test_Support.Write_Text_File
        (File_Path,
         "two" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("second");

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
      begin
         Second_Id := Version.Refs.Current_Commit_Id (Repo);
      end;

      Version.Tags.Create_Tag ("v2.0");
      Version.Tags.Create_Annotated_Tag ("v2-ann", "annotated second");

      declare
         Initial_Tags : constant String :=
           Version.Tags.List_Tags_Points_At_Text (Initial_Id);
         Second_Tags  : constant String :=
           Version.Tags.List_Tags_Points_At_Text (Second_Id);
         Head_Tags    : constant String :=
           Version.Tags.List_Tags_Points_At_Text ("HEAD");
         Contains_Initial : constant String :=
           Version.Tags.List_Tags_Containing_Text (Initial_Id);
         Contains_Second  : constant String :=
           Version.Tags.List_Tags_Containing_Text (Second_Id);
      begin
         Assert
           (Initial_Tags = "release/v1.0" & Character'Val (10)
            & "v1.0" & Character'Val (10),
            "points-at must list only tags whose refs exactly match the initial commit");

         Assert
           (Second_Tags = "v2-ann" & Character'Val (10)
            & "v2.0" & Character'Val (10),
            "points-at must list only tags whose refs exactly match the selected commit");

         Assert
           (Head_Tags = "v2-ann" & Character'Val (10)
            & "v2.0" & Character'Val (10),
            "points-at HEAD must list only tags whose refs exactly match HEAD");

         Assert
           (Contains_Initial = "release/v1.0" & Character'Val (10)
            & "v1.0" & Character'Val (10)
            & "v2-ann" & Character'Val (10)
            & "v2.0" & Character'Val (10),
            "contains must list tags whose peeled commit descends from revision");

         Assert
           (Ada.Strings.Fixed.Index (Initial_Tags, "broken") = 0,
            "points-at must omit malformed loose tag refs");
         Assert
           (Ada.Strings.Fixed.Index (Contains_Initial, "broken") = 0,
            "contains must omit malformed loose tag refs");

         Assert
           (Contains_Second = "v2-ann" & Character'Val (10)
            & "v2.0" & Character'Val (10),
            "contains must list tags at the selected commit");
      end;

      begin
         declare
            Ignored : constant String :=
              Version.Tags.List_Tags_Points_At_Text ("missing-revision");
            pragma Unreferenced (Ignored);
         begin
            null;
         end;
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert
        (Raised,
         "points-at must reject an unknown revision through revision resolution");

      begin
         declare
            Ignored : constant String :=
              Version.Tags.List_Tags_Containing_Text ("missing-revision");
            pragma Unreferenced (Ignored);
         begin
            null;
         end;
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Contains_Raised := True;
      end;

      Assert
        (Contains_Raised,
         "contains must reject an unknown revision through revision resolution");

      declare
         Tags : constant Version.Tags.Tag_Name_Vectors.Vector :=
           Version.Tags.List_Tags;
      begin
         Assert
           (Natural (Tags.Length) = 4,
            "points-at must not create or delete tags");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert
        (Version.Test_Support.Read_Text_File (Broken_Ref) = "not-an-object-id",
         "tag filters must not rewrite malformed loose tag refs");

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end List_Tags_Points_At_Revision;

   function Contains_Text
     (Haystack : String;
      Needle   : String) return Boolean
   is
   begin
      if Needle'Length = 0 then
         return True;
      end if;

      if Haystack'Length < Needle'Length then
         return False;
      end if;

      for I in Haystack'First .. Haystack'Last - Needle'Length + 1 loop
         if Haystack (I .. I + Needle'Length - 1) = Needle then
            return True;
         end if;
      end loop;

      return False;
   end Contains_Text;

   procedure Show_Tag_Text_Details
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String :=
        Ada.Directories.Current_Directory;

      File_Path : constant String :=
        Version.Test_Support.Join (Root, "a.txt");

      Raised : Boolean := False;
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");

      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (File_Path,
         "one" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("initial");

      Version.Tags.Create_Tag ("v1.0");
      Version.Tags.Create_Annotated_Tag ("v2.0", "annotated release");

      declare
         Repo      : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Commit_Id : constant String := Version.Refs.Current_Commit_Id (Repo);
         Light     : constant String := Version.Tags.Show_Tag_Text ("v1.0");
         Annotated : constant String := Version.Tags.Show_Tag_Text ("v2.0");
      begin
         Assert
           (Light = "name v1.0" & Character'Val (10)
            & "object " & Commit_Id & Character'Val (10)
            & "type commit" & Character'Val (10),
            "lightweight tag show output mismatch");

         Assert
           (Contains_Text (Annotated, "name v2.0" & Character'Val (10)),
            "annotated tag show must include tag name");
         Assert
           (Contains_Text (Annotated, "type tag" & Character'Val (10)),
            "annotated tag show must identify tag object");
         Assert
           (Contains_Text (Annotated, "target " & Commit_Id & Character'Val (10)),
            "annotated tag show must include peeled target");
         Assert
           (Contains_Text (Annotated, "target-type commit" & Character'Val (10)),
            "annotated tag show must include target type");
         Assert
           (Contains_Text
              (Annotated,
               "message" & Character'Val (10)
               & "annotated release" & Character'Val (10)),
            "annotated tag show must include message");
      end;

      Version.Git_Fixtures.Run (Root, "git pack-refs --all --prune");

      declare
         Repo      : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Commit_Id : constant String := Version.Refs.Current_Commit_Id (Repo);
         Packed    : constant String := Version.Tags.Show_Tag_Text ("v1.0");
      begin
         Assert
           (Packed = "name v1.0" & Character'Val (10)
            & "object " & Commit_Id & Character'Val (10)
            & "type commit" & Character'Val (10),
            "tag show must read packed tags");
      end;

      begin
         declare
            Ignored : constant String := Version.Tags.Show_Tag_Text ("missing");
            pragma Unreferenced (Ignored);
         begin
            null;
         end;
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "missing tag show must raise Data_Error");
      Assert
        (Natural (Version.Tags.List_Tags.Length) = 2,
         "tag show must not create or delete tags");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Show_Tag_Text_Details;

   overriding procedure Register_Tests
     (T : in out Test_Case)
   is
   begin
      Register_Routine
        (T,
         Create_List_Delete_Tag'Access,
         "Tags: create list delete");

      Register_Routine
        (T,
         Create_Tag_Rejects_Existing_Lock'Access,
         "Tags: create rejects existing lock");

      Register_Routine
         (T,
            Create_List_Delete_Nested_Tag'Access,
            "Tags: create list delete nested tag");

      Register_Routine
         (T,
          Rename_Tag_Preserves_Target_And_Fails_Safely'Access,
          "Tags: rename preserves target and fails safely");

      Register_Routine
         (T,
            List_Packed_Tags'Access,
            "Tags: list packed tags");

      Register_Routine
         (T,
            List_Tags_Is_Deterministic'Access,
            "Tags: list tags deterministically");

      Register_Routine
         (T,
            List_Tags_Omits_Malformed_Loose_Refs'Access,
            "Tags: list omits malformed loose refs");

      Register_Routine
        (T,
         Resolve_Loose_Tag'Access,
         "Tags: resolve loose tag");

      Register_Routine
        (T,
         Create_Annotated_Tag'Access,
         "Tags: create annotated tag");

      Register_Routine
        (T,
         Create_Tag_At_Explicit_Revision'Access,
         "Tags: create tag at explicit revision");

      Register_Routine
        (T,
         Resolve_Annotated_Tag'Access,
         "Tags: resolve annotated tag");

      Register_Routine
        (T,
         Resolve_Packed_Tag'Access,
         "Tags: resolve packed tag");

      Register_Routine
        (T,
         Resolve_Missing_Tag_Fails'Access,
         "Tags: resolve missing tag fails");

      Register_Routine
        (T,
         Tag_Exists_Is_Quiet_Predicate_And_Read_Only'Access,
         "Tags: exists predicate is read-only");
      Register_Routine
        (T,
         Tag_Exists_Returns_False_For_Malformed_Loose_Ref'Access,
         "Tags: exists rejects malformed loose tag refs");

      Register_Routine
        (T,
         List_Tags_Points_At_Revision'Access,
         "Tags: list tags pointing at revision");

      Register_Routine
        (T,
         Show_Tag_Text_Details'Access,
         "Tags: show tag details");

   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Tags");
   end Name;

end Version.Tags.Tests;