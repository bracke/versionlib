with Ada.Strings.Unbounded;

with Version.Files;
with Version.Objects;
with Version.Repository;
with Version.Staging;
with Version.Write;

with Project_Tools.Files;
with Project_Tools.Test_Fixtures;

--  Thin adapter over the shared project_tools test-fixture helpers, keeping the
--  Version.Test_Support API the test suites already use. The fixture logic
--  lives once in Project_Tools.Test_Fixtures / Project_Tools.Files.
package body Version.Test_Support is

   function Fresh_Temp_Dir (Name : String) return String is
   begin
      return Project_Tools.Test_Fixtures.Fresh_Temp_Dir (Name);
   end Fresh_Temp_Dir;

   procedure Cleanup (Path : String) is
   begin
      Project_Tools.Test_Fixtures.Cleanup (Path);
   end Cleanup;

   procedure Make_Directory (Path : String) is
   begin
      Project_Tools.Test_Fixtures.Make_Directory (Path);
   end Make_Directory;

   procedure Write_Text_File (Path : String; Content : String) is
   begin
      Project_Tools.Test_Fixtures.Write_Text_File (Path, Content);
   end Write_Text_File;

   function Read_Text_File (Path : String) return String is
   begin
      return Project_Tools.Test_Fixtures.Read_Text_File (Path);
   end Read_Text_File;

   function Join (Left : String; Right : String) return String is
   begin
      return Project_Tools.Files.Join (Left, Right);
   end Join;

   procedure Stage_Resolved_File
     (Root : String;
      Path : String)
   is
      use Ada.Strings.Unbounded;

      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
      Blob : constant Version.Objects.Hex_Object_Id :=
        Version.Write.Write_Blob
          (Repo, Version.Files.Read_Binary_File (Join (Root, Path)));
      Kept : Version.Staging.Index_Entry_Vectors.Vector;
   begin
      for E of Version.Staging.Load (Repo) loop
         if To_String (E.Path) /= Path then
            Kept.Append (E);
         end if;
      end loop;

      Kept.Append
        (Version.Staging.Index_Entry'
           (Path  => To_Unbounded_String (Path),
            Id    => Blob,
            Mode  => To_Unbounded_String ("100644"),
            Stage => 0, Skip_Worktree => False, Assume_Valid => False));
      Version.Staging.Sort_By_Path (Kept);
      Version.Staging.Write (Repo => Repo, Entries => Kept);
   end Stage_Resolved_File;

end Version.Test_Support;
