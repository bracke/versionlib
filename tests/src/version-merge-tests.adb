with Ada.IO_Exceptions;

with AUnit.Assertions;

package body Version.Merge.Tests is

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

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

   overriding procedure Register_Tests
     (T : in out Test_Case)
   is
   begin
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
