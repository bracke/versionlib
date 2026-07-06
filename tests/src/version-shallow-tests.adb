with Ada.Directories;
with Ada.IO_Exceptions;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Files;
with Version.Init;
with Version.Objects;
with Version.Repository;
with Version.Shallow_Cache;

package body Version.Shallow.Tests is
   use Version.Objects;

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

   A_Id : constant Version.Objects.Hex_Object_Id :=
     Version.Objects.To_Object_Id ("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
   B_Id : constant Version.Objects.Hex_Object_Id :=
     Version.Objects.To_Object_Id ("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");

   function Repo_For
     (T : in out AUnit.Test_Cases.Test_Case'Class)
      return Version.Repository.Repository_Handle
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);
      return Version.Repository.Open;
   end Repo_For;

   procedure Write_Reads_Deterministic_File
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      declare
         Repo  : constant Version.Repository.Repository_Handle := Repo_For (T);
         Items : Version.Objects.Object_Id_Vectors.Vector;
      begin
         Items.Append (B_Id);
         Items.Append (A_Id);
         Items.Append (A_Id);
         Version.Shallow.Write (Repo, Items);

         declare
            Read_Back : constant Version.Objects.Object_Id_Vectors.Vector :=
              Version.Shallow.Read (Repo);
            Content : constant String :=
              Version.Files.Read_Binary_File
                (Version.Files.Join (Version.Repository.Git_Dir (Repo), "shallow"));
         begin
            Assert (Natural (Read_Back.Length) = 2,
                    "shallow read should deduplicate ids");
            Assert (Read_Back.Element (0) = A_Id,
                    "shallow ids should be sorted");
            Assert (Read_Back.Element (1) = B_Id,
                    "second sorted id should be preserved");
            Assert (Content = To_String (A_Id) & Character'Val (10) & To_String (B_Id) & Character'Val (10),
                    "shallow file should be deterministic");
         end;
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Write_Reads_Deterministic_File;


   procedure Read_Deduplicates_File_With_Repeated_Boundaries
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      declare
         Repo : constant Version.Repository.Repository_Handle := Repo_For (T);
         Path : constant String :=
           Version.Files.Join (Version.Repository.Git_Dir (Repo), "shallow");
      begin
         Version.Files.Write_Binary_File
           (Path,
            To_String (B_Id) & Character'Val (10)
            & To_String (A_Id) & Character'Val (10)
            & To_String (B_Id) & Character'Val (10));

         declare
            Read_Back : constant Version.Objects.Object_Id_Vectors.Vector :=
              Version.Shallow.Read (Repo);
         begin
            Assert (Natural (Read_Back.Length) = 2,
                    "shallow read should remove repeated boundary ids");
            Assert (Read_Back.Element (0) = A_Id,
                    "deduplicated shallow read should remain sorted");
            Assert (Read_Back.Element (1) = B_Id,
                    "deduplicated shallow read should preserve second id");
         end;
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Read_Deduplicates_File_With_Repeated_Boundaries;

   procedure Add_And_Boundary_Lookup
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      declare
         Repo : constant Version.Repository.Repository_Handle := Repo_For (T);
      begin
         Version.Shallow.Add (Repo, A_Id);
         Assert (Version.Shallow.Exists (Repo), "shallow file should exist after add");
         Assert (Version.Shallow.Is_Shallow_Boundary (Repo, A_Id),
                 "added commit should be a shallow boundary");
         Assert (not Version.Shallow.Is_Shallow_Boundary (Repo, B_Id),
                 "unadded commit should not be a boundary");
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Add_And_Boundary_Lookup;


   procedure Remove_And_Empty_Write_Delete_File
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      declare
         Repo  : constant Version.Repository.Repository_Handle := Repo_For (T);
         Items : Version.Objects.Object_Id_Vectors.Vector;
         Path  : constant String :=
           Version.Files.Join (Version.Repository.Git_Dir (Repo), "shallow");
      begin
         Items.Append (A_Id);
         Items.Append (B_Id);
         Version.Shallow.Write (Repo, Items);
         Version.Shallow.Remove (Repo, A_Id);

         Assert (not Version.Shallow.Is_Shallow_Boundary (Repo, A_Id),
                 "removed id should not remain a boundary");
         Assert (Version.Shallow.Is_Shallow_Boundary (Repo, B_Id),
                 "other boundary should be preserved");

         Items.Clear;
         Version.Shallow.Write (Repo, Items);
         Assert (not Ada.Directories.Exists (Path),
                 "empty shallow write should remove the shallow file");
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Remove_And_Empty_Write_Delete_File;


   procedure Shallow_Cache_Loads_Boundaries_Once
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      declare
         Repo  : constant Version.Repository.Repository_Handle := Repo_For (T);
         Items : Version.Objects.Object_Id_Vectors.Vector;
         Cache : Version.Shallow_Cache.Shallow_Cache;
      begin
         Items.Append (A_Id);
         Version.Shallow.Write (Repo, Items);

         Assert
           (Version.Shallow_Cache.Is_Boundary
              (Repo      => Repo,
               Cache     => Cache,
               Commit_Id => A_Id),
            "cached shallow lookup should find the loaded boundary");
         Assert
           (Version.Shallow_Cache.Cached_Boundary_Count (Cache) = 1,
            "cache should hold the loaded shallow boundary set");

         Items.Append (B_Id);
         Version.Shallow.Write (Repo, Items);

         Assert
           (not Version.Shallow_Cache.Is_Boundary
              (Repo      => Repo,
               Cache     => Cache,
               Commit_Id => B_Id),
            "loaded command-local shallow cache should not reread after file mutation");

         Version.Shallow_Cache.Clear (Cache);
         Assert
           (Version.Shallow_Cache.Is_Boundary
              (Repo      => Repo,
               Cache     => Cache,
               Commit_Id => B_Id),
            "cleared shallow cache should reload current file contents");
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Shallow_Cache_Loads_Boundaries_Once;

   procedure Malformed_File_Raises
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      declare
         Repo : constant Version.Repository.Repository_Handle := Repo_For (T);
      begin
         Version.Files.Write_Binary_File
           (Version.Files.Join (Version.Repository.Git_Dir (Repo), "shallow"),
            "not-an-object" & Character'Val (10));

         begin
            declare
               Items : constant Version.Objects.Object_Id_Vectors.Vector :=
                 Version.Shallow.Read (Repo);
               pragma Unreferenced (Items);
            begin
               null;
            end;
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;

         Assert (Raised, "malformed shallow file should raise Data_Error");
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Malformed_File_Raises;

   overriding procedure Register_Tests
     (T : in out Test_Case)
   is
   begin
      Register_Routine (T, Write_Reads_Deterministic_File'Access,
                        "Shallow write/read sorts and deduplicates ids");
      Register_Routine (T, Read_Deduplicates_File_With_Repeated_Boundaries'Access,
                        "Shallow read deduplicates repeated boundary ids");
      Register_Routine (T, Add_And_Boundary_Lookup'Access,
                        "Shallow add and boundary lookup");
      Register_Routine (T, Remove_And_Empty_Write_Delete_File'Access,
                        "Shallow remove and empty write remove file");
      Register_Routine (T, Shallow_Cache_Loads_Boundaries_Once'Access,
                        "Shallow cache loads boundaries once per command");
      Register_Routine (T, Malformed_File_Raises'Access,
                        "Shallow rejects malformed file");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Shallow");
   end Name;

end Version.Shallow.Tests;
