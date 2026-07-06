with Ada.Directories;
with Version.Test_Support;

package body Version.Temp_Fixture is

   use Ada.Strings.Unbounded;

   overriding procedure Set_Up
     (T : in out Test_Case)
   is
   begin
      T.Start_Dir := To_Unbounded_String (Ada.Directories.Current_Directory);
      T.Root_Path :=
        To_Unbounded_String
          (Version.Test_Support.Fresh_Temp_Dir ("fixture"));
   end Set_Up;

   overriding procedure Tear_Down
     (T : in out Test_Case)
   is
   begin
      if Length (T.Start_Dir) > 0 then
         begin
            Ada.Directories.Set_Directory (To_String (T.Start_Dir));
         exception
            when others =>
               null;
         end;
      end if;

      if Length (T.Root_Path) > 0 then
         Version.Test_Support.Cleanup (To_String (T.Root_Path));
         T.Root_Path := Null_Unbounded_String;
      end if;

      T.Start_Dir := Null_Unbounded_String;
   end Tear_Down;

   function Root
     (T : Test_Case)
      return String
   is
   begin
      return To_String (T.Root_Path);
   end Root;

end Version.Temp_Fixture;