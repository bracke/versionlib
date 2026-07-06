with Version.Objects;
with Ada.Directories;
with Ada.Strings.Unbounded;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Branch;
with Version.Git_Fixtures;
with Version.Init;
with Version.Refs;
with Version.Repository;
with Version.Test_Support;
with Version.Write;

package body Version.Bundle.Tests is
   use Version.Objects;

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;
   use Ada.Strings.Unbounded;

   LF : constant Character := Character'Val (10);

   procedure Configure_Repo (Root : String) is
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");
   end Configure_Repo;

   procedure Create_Roundtrip_And_Git_Verify
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Bundle_File : constant String :=
        Version.Test_Support.Join (Root, "test.bundle");
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "f.txt"), "a" & LF);
      Version.Git_Fixtures.Run (Root, "git add f.txt");
      Version.Write.Save ("c1");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "f.txt"), "a" & LF & "b" & LF);
      Version.Git_Fixtures.Run (Root, "git add f.txt");
      Version.Write.Save ("c2");

      declare
         Repo   : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Branch : constant String := Version.Branch.Current_Branch_Name;
         Ref_Name : constant String := "refs/heads/" & Branch;
         Refs   : Version.Bundle.Ref_Vectors.Vector;
      begin
         Refs.Append
           (Version.Bundle.Ref_Entry'
              (Id   => Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Repo)),
               Name => To_Unbounded_String (Ref_Name)));

         Version.Bundle.Create (Repo, Bundle_File, Refs);

         --  Header round-trips through our own reader.
         declare
            Info : constant Version.Bundle.Bundle_Info :=
              Version.Bundle.Read_Header (Bundle_File);
         begin
            Assert (Natural (Info.Refs.Length) = 1,
                    "bundle must record exactly one ref");
            Assert (To_String (Info.Refs.Element (1).Name) = Ref_Name,
                    "bundle ref name must round-trip");
            Assert (Info.Refs.Element (1).Id
                      = Version.Refs.Current_Commit_Id (Repo),
                    "bundle ref id must match the branch tip");
            Assert (Info.Complete,
                    "a full bundle must record a complete history");
         end;

         --  Real git accepts the bundle we wrote.
         Version.Git_Fixtures.Run (Root, "git bundle verify test.bundle");
      end;
   end Create_Roundtrip_And_Git_Verify;

   overriding procedure Register_Tests (T : in out Test_Case) is
   begin
      Register_Routine
        (T, Create_Roundtrip_And_Git_Verify'Access,
         "Bundle: create round-trips and is accepted by git bundle verify");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Bundle");
   end Name;

end Version.Bundle.Tests;
