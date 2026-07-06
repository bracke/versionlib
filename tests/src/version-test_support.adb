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

end Version.Test_Support;
