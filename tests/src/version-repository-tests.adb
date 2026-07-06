with Ada.Directories;
with Ada.Exceptions;
with Ada.IO_Exceptions;
with AUnit.Assertions;
with AUnit.Test_Cases;
with Version.Files;
with Version.Git_Fixtures;
with Version.Platform;
with Version.Test_Support;
with Version.Transport.Local;

package body Version.Repository.Tests is

   use AUnit.Assertions;
   use type Version.Platform.Platform_Kind;

   procedure Assert_Local_Transport_Data_Error
     (Root     : String;
      Expected : String;
      Context  : String)
   is
      Raised : Boolean := False;
   begin
      begin
         declare
            Ignored : constant String :=
              Version.Transport.Local.Resolve_Git_Dir (Root);
         begin
            pragma Unreferenced (Ignored);
         end;
      exception
         when E : Ada.IO_Exceptions.Data_Error =>
            Raised := True;
            Assert
              (Ada.Exceptions.Exception_Message (E) = Expected,
               Context & " diagnostic mismatch: "
               & Ada.Exceptions.Exception_Message (E));
      end;

      Assert (Raised, Context & " must raise Data_Error");
   end Assert_Local_Transport_Data_Error;

   procedure Open_Finds_Git_Directory
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root     : constant String := Version.Temp_Fixture.Root
  (Version.Temp_Fixture.Test_Case (T));
      Old_Dir  : constant String := Ada.Directories.Current_Directory;
      Dot_Git  : constant String := Version.Test_Support.Join (Root, ".git");
      Child    : constant String := Version.Test_Support.Join (Root, "child");
   begin
      Version.Test_Support.Make_Directory (Dot_Git);
      Version.Test_Support.Make_Directory (Child);
      Ada.Directories.Set_Directory (Child);

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
      begin
         Assert (Version.Repository.Root_Path (Repo) = Root,
                 "Repository root was not discovered from child directory");
         Assert (Version.Repository.Git_Dir (Repo) = Dot_Git,
                 "Git directory path is incorrect");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Open_Finds_Git_Directory;

   procedure Open_Resolves_Git_File
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root      : constant String := Version.Temp_Fixture.Root
  (Version.Temp_Fixture.Test_Case (T));
      Old_Dir   : constant String := Ada.Directories.Current_Directory;
      Real_Git  : constant String := Version.Test_Support.Join (Root, "actual_git");
      Dot_Git   : constant String := Version.Test_Support.Join (Root, ".git");
   begin
      Version.Test_Support.Make_Directory (Real_Git);
      Version.Test_Support.Write_Text_File (Dot_Git, "gitdir: actual_git");
      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
      begin
         Assert (Version.Repository.Git_Dir (Repo) = Real_Git,
                 ".git file did not resolve to expected gitdir");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Open_Resolves_Git_File;

   procedure Local_Transport_Resolves_Dot_Git_Directory
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Dot_Git : constant String := Version.Test_Support.Join (Root, ".git");
   begin
      Version.Test_Support.Make_Directory (Dot_Git);

      Assert
        (Version.Transport.Local.Resolve_Git_Dir (Root) = Dot_Git,
         "local transport must resolve a non-bare .git directory");
   end Local_Transport_Resolves_Dot_Git_Directory;

   procedure Local_Transport_Resolves_Bare_Repository
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Objects : constant String := Version.Test_Support.Join (Root, "objects");
   begin
      Version.Test_Support.Make_Directory (Objects);

      Assert
        (Version.Transport.Local.Resolve_Git_Dir (Root) = Root,
         "local transport must resolve a bare repository object store");
   end Local_Transport_Resolves_Bare_Repository;

   procedure Local_Transport_Resolves_Gitdir_File
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root     : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Real_Git : constant String := Version.Test_Support.Join (Root, "actual_git");
      Dot_Git  : constant String := Version.Test_Support.Join (Root, ".git");
   begin
      Version.Test_Support.Make_Directory (Real_Git);
      Version.Test_Support.Write_Text_File
        (Dot_Git, "gitdir: actual_git" & Character'Val (10));

      Assert
        (Version.Transport.Local.Resolve_Git_Dir (Root) = Real_Git,
         "local transport must resolve relative .git gitdir files");
   end Local_Transport_Resolves_Gitdir_File;

   procedure Local_Transport_Rejects_Invalid_Gitdir_File
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Dot_Git : constant String := Version.Test_Support.Join (Root, ".git");
      Missing : constant String := Version.Test_Support.Join (Root, "missing");
   begin
      Version.Test_Support.Write_Text_File
        (Dot_Git, "gitdir: missing" & Character'Val (10));

      Assert_Local_Transport_Data_Error
        (Root,
         "remote gitdir target does not exist: " & Missing,
         "missing local transport gitdir target");
   end Local_Transport_Rejects_Invalid_Gitdir_File;

   procedure Local_Transport_Rejects_Escaping_Gitdir_File
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Dot_Git : constant String := Version.Test_Support.Join (Root, ".git");
   begin
      Version.Test_Support.Write_Text_File
        (Dot_Git, "gitdir: ../escape" & Character'Val (10));

      Assert_Local_Transport_Data_Error
        (Root,
         "invalid remote .git gitdir file: " & Root,
         "escaping local transport gitdir target");
   end Local_Transport_Rejects_Escaping_Gitdir_File;

   procedure Local_Transport_Rejects_Malformed_Gitdir_File
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Dot_Git : constant String := Version.Test_Support.Join (Root, ".git");
   begin
      Version.Test_Support.Write_Text_File
        (Dot_Git, "not a gitdir" & Character'Val (10));

      Assert_Local_Transport_Data_Error
        (Root,
         "remote .git file does not contain gitdir: " & Root,
         "malformed local transport .git file");
   end Local_Transport_Rejects_Malformed_Gitdir_File;

   procedure Local_Transport_Rejects_Empty_Gitdir_File
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Dot_Git : constant String := Version.Test_Support.Join (Root, ".git");
   begin
      Version.Test_Support.Write_Text_File
        (Dot_Git, "gitdir: " & Character'Val (10));

      Assert_Local_Transport_Data_Error
        (Root,
         "invalid remote .git gitdir file: " & Root,
         "empty local transport gitdir target");
   end Local_Transport_Rejects_Empty_Gitdir_File;

   procedure Local_Transport_Rejects_Non_Repository_Path
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
   begin
      Assert_Local_Transport_Data_Error
        (Root,
         "remote is not a local Git repository: " & Root,
         "non-repository local transport path");
   end Local_Transport_Rejects_Non_Repository_Path;

   procedure Local_Transport_Copies_Valid_Loose_Object
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Source_Git : constant String := Version.Test_Support.Join (Root, "source.git");
      Target_Git : constant String := Version.Test_Support.Join (Root, "target.git");
      Source_Dir : constant String :=
        Version.Files.Join (Version.Files.Join (Source_Git, "objects"), "aa");
      Target_Dir : constant String :=
        Version.Files.Join (Version.Files.Join (Target_Git, "objects"), "aa");
      Source_Object : constant String :=
        Version.Files.Join (Source_Dir, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
      Target_Object : constant String :=
        Version.Files.Join (Target_Dir, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
   begin
      Version.Test_Support.Make_Directory (Source_Dir);
      Version.Test_Support.Write_Text_File (Source_Object, "object content");

      Version.Transport.Local.Copy_Object_Store
        (Source_Git_Dir => Source_Git,
         Target_Git_Dir => Target_Git);

      Assert
        (Version.Test_Support.Read_Text_File (Target_Object) = "object content",
         "local object-store copy must preserve valid loose object content");
   end Local_Transport_Copies_Valid_Loose_Object;

   procedure Local_Transport_Rejects_Invalid_Object_Store_Entry
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Source_Git : constant String := Version.Test_Support.Join (Root, "source.git");
      Target_Git : constant String := Version.Test_Support.Join (Root, "target.git");
      Objects : constant String := Version.Files.Join (Source_Git, "objects");
      Invalid : constant String := Version.Files.Join (Objects, "not-an-object");
      Raised : Boolean := False;
   begin
      Version.Test_Support.Make_Directory (Objects);
      Version.Test_Support.Write_Text_File (Invalid, "not an object");

      begin
         Version.Transport.Local.Copy_Object_Store
           (Source_Git_Dir => Source_Git,
            Target_Git_Dir => Target_Git);
      exception
         when E : Ada.IO_Exceptions.Data_Error =>
            Raised := True;
            Assert
              (Ada.Exceptions.Exception_Message (E)
               = "invalid local object-store entry: " & Invalid,
               "wrong invalid object-store entry diagnostic: "
               & Ada.Exceptions.Exception_Message (E));
      end;

      Assert (Raised, "local object-store copy must reject malformed entries");
   end Local_Transport_Rejects_Invalid_Object_Store_Entry;

   procedure Local_Transport_Invalid_Entry_Does_Not_Copy_Objects
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Source_Git : constant String := Version.Test_Support.Join (Root, "source.git");
      Target_Git : constant String := Version.Test_Support.Join (Root, "target.git");
      Source_Dir : constant String :=
        Version.Files.Join (Version.Files.Join (Source_Git, "objects"), "aa");
      Objects : constant String := Version.Files.Join (Source_Git, "objects");
      Source_Object : constant String :=
        Version.Files.Join (Source_Dir, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
      Target_Object : constant String :=
        Version.Files.Join
          (Version.Files.Join
             (Version.Files.Join (Target_Git, "objects"), "aa"),
           "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
      Invalid : constant String := Version.Files.Join (Objects, "not-an-object");
      Raised : Boolean := False;
   begin
      Version.Test_Support.Make_Directory (Source_Dir);
      Version.Test_Support.Write_Text_File (Source_Object, "object content");
      Version.Test_Support.Write_Text_File (Invalid, "not an object");

      begin
         Version.Transport.Local.Copy_Object_Store
           (Source_Git_Dir => Source_Git,
            Target_Git_Dir => Target_Git);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "invalid object-store entry must fail copy");
      Assert
        (not Ada.Directories.Exists (Target_Object),
         "invalid object-store entry must not leave earlier copied objects");
   end Local_Transport_Invalid_Entry_Does_Not_Copy_Objects;

   procedure Local_Transport_Collision_Does_Not_Copy_Objects
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Source_Git : constant String := Version.Test_Support.Join (Root, "source.git");
      Target_Git : constant String := Version.Test_Support.Join (Root, "target.git");
      Source_AA : constant String :=
        Version.Files.Join (Version.Files.Join (Source_Git, "objects"), "aa");
      Source_BB : constant String :=
        Version.Files.Join (Version.Files.Join (Source_Git, "objects"), "bb");
      Target_AA : constant String :=
        Version.Files.Join (Version.Files.Join (Target_Git, "objects"), "aa");
      Target_BB : constant String :=
        Version.Files.Join (Version.Files.Join (Target_Git, "objects"), "bb");
      Source_New : constant String :=
        Version.Files.Join (Source_AA, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
      Target_New : constant String :=
        Version.Files.Join (Target_AA, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
      Source_Collision : constant String :=
        Version.Files.Join (Source_BB, "cccccccccccccccccccccccccccccccccccccc");
      Target_Collision : constant String :=
        Version.Files.Join (Target_BB, "cccccccccccccccccccccccccccccccccccccc");
      Raised : Boolean := False;
   begin
      Version.Test_Support.Make_Directory (Source_AA);
      Version.Test_Support.Make_Directory (Source_BB);
      Version.Test_Support.Make_Directory (Target_BB);
      Version.Test_Support.Write_Text_File (Source_New, "new object");
      Version.Test_Support.Write_Text_File (Source_Collision, "source object");
      Version.Test_Support.Write_Text_File (Target_Collision, "target object");

      begin
         Version.Transport.Local.Copy_Object_Store
           (Source_Git_Dir => Source_Git,
            Target_Git_Dir => Target_Git);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "object-store collision must fail copy");
      Assert
        (not Ada.Directories.Exists (Target_New),
         "object-store collision must not leave earlier copied objects");
   end Local_Transport_Collision_Does_Not_Copy_Objects;

   procedure Local_Transport_Copies_Allowed_Metadata_Files
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Source_Git : constant String := Version.Test_Support.Join (Root, "source.git");
      Target_Git : constant String := Version.Test_Support.Join (Root, "target.git");
      Source_Pack : constant String :=
        Version.Files.Join (Version.Files.Join (Source_Git, "objects"), "pack");
      Source_Info : constant String :=
        Version.Files.Join (Version.Files.Join (Source_Git, "objects"), "info");
      Pack_File : constant String := Version.Files.Join (Source_Pack, "pack-test.pack");
      Info_File : constant String := Version.Files.Join (Source_Info, "packs");
      Target_Pack : constant String :=
        Version.Files.Join
          (Version.Files.Join
             (Version.Files.Join (Target_Git, "objects"), "pack"),
           "pack-test.pack");
      Target_Info : constant String :=
        Version.Files.Join
          (Version.Files.Join
             (Version.Files.Join (Target_Git, "objects"), "info"),
           "packs");
   begin
      Version.Test_Support.Make_Directory (Source_Pack);
      Version.Test_Support.Make_Directory (Source_Info);
      Version.Test_Support.Write_Text_File (Pack_File, "pack metadata");
      Version.Test_Support.Write_Text_File (Info_File, "P pack-test.pack" & Character'Val (10));

      Version.Transport.Local.Copy_Object_Store
        (Source_Git_Dir => Source_Git,
         Target_Git_Dir => Target_Git);

      Assert
        (Version.Test_Support.Read_Text_File (Target_Pack) = "pack metadata",
         "allowed pack metadata file must be copied");
      Assert
        (Version.Test_Support.Read_Text_File (Target_Info) = "P pack-test.pack",
         "allowed info metadata file must be copied");
   end Local_Transport_Copies_Allowed_Metadata_Files;

   procedure Local_Transport_Rejects_Invalid_Metadata_File
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Source_Git : constant String := Version.Test_Support.Join (Root, "source.git");
      Target_Git : constant String := Version.Test_Support.Join (Root, "target.git");
      Source_Dir : constant String :=
        Version.Files.Join (Version.Files.Join (Source_Git, "objects"), "aa");
      Pack_Dir : constant String :=
        Version.Files.Join (Version.Files.Join (Source_Git, "objects"), "pack");
      Source_Object : constant String :=
        Version.Files.Join (Source_Dir, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
      Target_Object : constant String :=
        Version.Files.Join
          (Version.Files.Join
             (Version.Files.Join (Target_Git, "objects"), "aa"),
           "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
      Invalid : constant String := Version.Files.Join (Pack_Dir, "scratch.tmp");
      Raised : Boolean := False;
   begin
      Version.Test_Support.Make_Directory (Source_Dir);
      Version.Test_Support.Make_Directory (Pack_Dir);
      Version.Test_Support.Write_Text_File (Source_Object, "object content");
      Version.Test_Support.Write_Text_File (Invalid, "invalid metadata");

      begin
         Version.Transport.Local.Copy_Object_Store
           (Source_Git_Dir => Source_Git,
            Target_Git_Dir => Target_Git);
      exception
         when E : Ada.IO_Exceptions.Data_Error =>
            Raised := True;
            Assert
              (Ada.Exceptions.Exception_Message (E)
               = "invalid local object-store entry: " & Invalid,
               "wrong invalid metadata diagnostic: "
               & Ada.Exceptions.Exception_Message (E));
      end;

      Assert (Raised, "invalid pack metadata file must fail copy");
      Assert
        (not Ada.Directories.Exists (Target_Object),
         "invalid metadata file must not leave earlier copied objects");
   end Local_Transport_Rejects_Invalid_Metadata_File;

   procedure Local_Transport_Rejects_Alternates_Metadata
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Source_Git : constant String := Version.Test_Support.Join (Root, "source.git");
      Target_Git : constant String := Version.Test_Support.Join (Root, "target.git");
      Source_Dir : constant String :=
        Version.Files.Join (Version.Files.Join (Source_Git, "objects"), "aa");
      Info_Dir : constant String :=
        Version.Files.Join (Version.Files.Join (Source_Git, "objects"), "info");
      Source_Object : constant String :=
        Version.Files.Join (Source_Dir, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
      Target_Object : constant String :=
        Version.Files.Join
          (Version.Files.Join
             (Version.Files.Join (Target_Git, "objects"), "aa"),
           "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
      Alternates : constant String := Version.Files.Join (Info_Dir, "alternates");
      Raised : Boolean := False;
   begin
      Version.Test_Support.Make_Directory (Source_Dir);
      Version.Test_Support.Make_Directory (Info_Dir);
      Version.Test_Support.Write_Text_File (Source_Object, "object content");
      Version.Test_Support.Write_Text_File (Alternates, "../outside/objects" & Character'Val (10));

      begin
         Version.Transport.Local.Copy_Object_Store
           (Source_Git_Dir => Source_Git,
            Target_Git_Dir => Target_Git);
      exception
         when E : Ada.IO_Exceptions.Data_Error =>
            Raised := True;
            Assert
              (Ada.Exceptions.Exception_Message (E)
               = "invalid local object-store entry: " & Alternates,
               "wrong alternates metadata diagnostic: "
               & Ada.Exceptions.Exception_Message (E));
      end;

      Assert (Raised, "alternates metadata must fail local object copy");
      Assert
        (not Ada.Directories.Exists (Target_Object),
         "alternates metadata must not leave earlier copied objects");
   end Local_Transport_Rejects_Alternates_Metadata;

   procedure Local_Transport_Rejects_Nested_Metadata_Directory
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Source_Git : constant String := Version.Test_Support.Join (Root, "source.git");
      Target_Git : constant String := Version.Test_Support.Join (Root, "target.git");
      Info_Dir : constant String :=
        Version.Files.Join (Version.Files.Join (Source_Git, "objects"), "info");
      Nested : constant String := Version.Files.Join (Info_Dir, "nested");
      Raised : Boolean := False;
   begin
      Version.Test_Support.Make_Directory (Nested);

      begin
         Version.Transport.Local.Copy_Object_Store
           (Source_Git_Dir => Source_Git,
            Target_Git_Dir => Target_Git);
      exception
         when E : Ada.IO_Exceptions.Data_Error =>
            Raised := True;
            Assert
              (Ada.Exceptions.Exception_Message (E)
               = "invalid local object-store entry: " & Nested,
               "wrong nested metadata diagnostic: "
               & Ada.Exceptions.Exception_Message (E));
      end;

      Assert (Raised, "nested object metadata directories must fail copy");
   end Local_Transport_Rejects_Nested_Metadata_Directory;

   procedure Local_Transport_Rejects_Special_Object_Entry
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Source_Git : constant String := Version.Test_Support.Join (Root, "source.git");
      Target_Git : constant String := Version.Test_Support.Join (Root, "target.git");
      Source_Dir : constant String :=
        Version.Files.Join (Version.Files.Join (Source_Git, "objects"), "aa");
      Pack_Dir : constant String :=
        Version.Files.Join (Version.Files.Join (Source_Git, "objects"), "pack");
      Source_Object : constant String :=
        Version.Files.Join (Source_Dir, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
      Target_Object : constant String :=
        Version.Files.Join
          (Version.Files.Join
             (Version.Files.Join (Target_Git, "objects"), "aa"),
           "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
      Link_Path : constant String := Version.Files.Join (Pack_Dir, "link.pack");
      Raised : Boolean := False;
   begin
      if Version.Platform.Current /= Version.Platform.POSIX_Platform then
         return;
      end if;

      Version.Test_Support.Make_Directory (Source_Dir);
      Version.Test_Support.Make_Directory (Pack_Dir);
      Version.Test_Support.Write_Text_File (Source_Object, "object content");
      Version.Git_Fixtures.Run
        (Pack_Dir,
         "ln -s ../aa/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb link.pack");

      begin
         Version.Transport.Local.Copy_Object_Store
           (Source_Git_Dir => Source_Git,
            Target_Git_Dir => Target_Git);
      exception
         when E : Ada.IO_Exceptions.Data_Error =>
            Raised := True;
            Assert
              (Ada.Exceptions.Exception_Message (E)
               = "invalid local object-store entry: " & Link_Path,
               "wrong special object-store entry diagnostic: "
               & Ada.Exceptions.Exception_Message (E));
      end;

      Assert (Raised, "special object-store entries must fail copy");
      Assert
        (not Ada.Directories.Exists (Target_Object),
         "special object-store entry must not leave earlier copied objects");
   end Local_Transport_Rejects_Special_Object_Entry;

   procedure Local_Transport_Rejects_Object_Collision
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Source_Git : constant String := Version.Test_Support.Join (Root, "source.git");
      Target_Git : constant String := Version.Test_Support.Join (Root, "target.git");
      Source_Dir : constant String :=
        Version.Files.Join (Version.Files.Join (Source_Git, "objects"), "aa");
      Target_Dir : constant String :=
        Version.Files.Join (Version.Files.Join (Target_Git, "objects"), "aa");
      Source_Object : constant String := Version.Files.Join (Source_Dir, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
      Target_Object : constant String := Version.Files.Join (Target_Dir, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
      Raised : Boolean := False;
   begin
      Version.Test_Support.Make_Directory (Source_Dir);
      Version.Test_Support.Make_Directory (Target_Dir);
      Version.Test_Support.Write_Text_File (Source_Object, "source object");
      Version.Test_Support.Write_Text_File (Target_Object, "target object");

      begin
         Version.Transport.Local.Copy_Object_Store
           (Source_Git_Dir => Source_Git,
            Target_Git_Dir => Target_Git);
      exception
         when E : Ada.IO_Exceptions.Data_Error =>
            Raised := True;
            Assert
              (Ada.Exceptions.Exception_Message (E)
               = "local object collision while copying object store: "
                 & Target_Object,
               "wrong local object collision diagnostic: "
               & Ada.Exceptions.Exception_Message (E));
      end;

      Assert (Raised, "local object-store copy must reject content collisions");
   end Local_Transport_Rejects_Object_Collision;

   overriding procedure Register_Tests
     (T : in out Test_Case)
   is
   begin
      AUnit.Test_Cases.Registration.Register_Routine (T, Open_Finds_Git_Directory'Access,
                        "Open finds .git directory from child");
      AUnit.Test_Cases.Registration.Register_Routine (T, Open_Resolves_Git_File'Access,
                        "Open resolves .git gitdir file");
      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Local_Transport_Resolves_Dot_Git_Directory'Access,
         "Transport.Local: resolves .git directory");
      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Local_Transport_Resolves_Bare_Repository'Access,
         "Transport.Local: resolves bare repository");
      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Local_Transport_Resolves_Gitdir_File'Access,
         "Transport.Local: resolves .git gitdir file");
      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Local_Transport_Rejects_Invalid_Gitdir_File'Access,
         "Transport.Local: rejects invalid .git gitdir file");
      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Local_Transport_Rejects_Escaping_Gitdir_File'Access,
         "Transport.Local: rejects escaping .git gitdir file");
      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Local_Transport_Rejects_Malformed_Gitdir_File'Access,
         "Transport.Local: rejects malformed .git gitdir file");
      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Local_Transport_Rejects_Empty_Gitdir_File'Access,
         "Transport.Local: rejects empty .git gitdir file");
      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Local_Transport_Rejects_Non_Repository_Path'Access,
         "Transport.Local: rejects non-repository path");
      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Local_Transport_Copies_Valid_Loose_Object'Access,
         "Transport.Local: copies valid loose objects");
      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Local_Transport_Rejects_Invalid_Object_Store_Entry'Access,
         "Transport.Local: rejects invalid object-store entries");
      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Local_Transport_Invalid_Entry_Does_Not_Copy_Objects'Access,
         "Transport.Local: invalid object-store entry does not copy objects");
      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Local_Transport_Rejects_Object_Collision'Access,
         "Transport.Local: rejects object-store collisions");
      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Local_Transport_Collision_Does_Not_Copy_Objects'Access,
         "Transport.Local: object-store collision does not copy objects");
      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Local_Transport_Copies_Allowed_Metadata_Files'Access,
         "Transport.Local: copies allowed object metadata files");
      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Local_Transport_Rejects_Invalid_Metadata_File'Access,
         "Transport.Local: rejects invalid object metadata files");
      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Local_Transport_Rejects_Alternates_Metadata'Access,
         "Transport.Local: rejects alternates object metadata");
      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Local_Transport_Rejects_Nested_Metadata_Directory'Access,
         "Transport.Local: rejects nested object metadata directories");
      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Local_Transport_Rejects_Special_Object_Entry'Access,
         "Transport.Local: rejects special object-store entries");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Repository");
   end Name;

end Version.Repository.Tests;
