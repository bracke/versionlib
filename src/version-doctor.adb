with Ada.Directories;
with Ada.Exceptions;
with Ada.IO_Exceptions;
with GNAT.OS_Lib;

with Version.Files;
with Version.Refs;
with Version.Repository;
with Version.Repository_Format;
with Version.Staging;

package body Version.Doctor is

   use Ada.Strings.Unbounded;

   procedure Append_Line
     (Text : in out Unbounded_String;
      Line : String)
   is
   begin
      Append (Text, Line);
      Append (Text, Character'Val (10));
   end Append_Line;

   function Status_Text (Status : Check_Status) return String is
   begin
      case Status is
         when Pass => return "ok";
         when Warn => return "warn";
         when Fail => return "fail";
      end case;
   end Status_Text;

   procedure Note
     (Result : in out Doctor_Result;
      Status : Check_Status;
      Text   : String)
   is
   begin
      Append_Line (Result.Message, Status_Text (Status) & ": " & Text);
   end Note;

   function Check_Repository return Doctor_Result is
      Result : Doctor_Result;
   begin
      begin
         declare
            Repo : constant Version.Repository.Repository_Handle :=
              Version.Repository.Open;
            Info : constant Version.Repository_Format.Format_Info :=
              Version.Repository_Format.Read (Version.Repository.Common_Git_Dir (Repo));
            pragma Unreferenced (Info);
         begin
            Result.Repository_Status := Pass;
            Note (Result, Pass, "repository found at " & Version.Repository.Root_Path (Repo));

            begin
               Version.Repository_Format.Require_Compatible
                 (Git_Dir  => Version.Repository.Common_Git_Dir (Repo),
                  Mutation => False);
               Result.Object_Format_Status := Pass;
               Note (Result, Pass, "repository format is supported");
            exception
               when E : Ada.IO_Exceptions.Data_Error =>
                  Result.Object_Format_Status := Fail;
                  Note (Result, Fail, Ada.Exceptions.Exception_Message (E));
            end;

            begin
               declare
                  Head : constant Version.Refs.Head_Info := Version.Refs.Read_Head (Repo);
                  pragma Unreferenced (Head);
               begin
                  Result.Head_Status := Pass;
                  Note (Result, Pass, "HEAD is readable");
               end;
            exception
               when E : others =>
                  Result.Head_Status := Fail;
                  Note (Result, Fail, "HEAD is not readable: " & Ada.Exceptions.Exception_Message (E));
            end;

            begin
               declare
                  Entries : constant Version.Staging.Index_Entry_Vectors.Vector :=
                    Version.Staging.Load (Repo);
                  pragma Unreferenced (Entries);
               begin
                  Result.Index_Status := Pass;
                  Note (Result, Pass, "index is readable");
               end;
            exception
               when E : others =>
                  Result.Index_Status := Fail;
                  Note (Result, Fail, "index is not readable: " & Ada.Exceptions.Exception_Message (E));
            end;
         end;
      exception
         when E : others =>
            Result.Repository_Status := Fail;
            Result.Object_Format_Status := Fail;
            Result.Head_Status := Fail;
            Result.Index_Status := Fail;
            Note (Result, Fail, "repository not usable: " & Ada.Exceptions.Exception_Message (E));
      end;

      return Result;
   end Check_Repository;

   function Result_Text
     (Result : Doctor_Result)
      return String
   is
      Text : Unbounded_String;
   begin
      Append_Line (Text, "version doctor");
      Append_Line (Text, "repository: " & Status_Text (Result.Repository_Status));
      Append_Line (Text, "format: " & Status_Text (Result.Object_Format_Status));
      Append_Line (Text, "HEAD: " & Status_Text (Result.Head_Status));
      Append_Line (Text, "index: " & Status_Text (Result.Index_Status));
      Append (Text, Result.Message);
      return To_String (Text);
   end Result_Text;

   function Release_Check_Text return String is
      Text : Unbounded_String;
   begin
      Append_Line (Text, "version doctor --release");
      Append_Line
        (Text,
         "runs release consistency, documentation, test-scope, " &
         "and package self-test gates from the source tree");
      Append_Line (Text, "required gates:");
      Append_Line (Text, "  tools/bin/check_version_metadata");
      Append_Line (Text, "  tools/bin/check_documentation_coherence");
      Append_Line (Text, "  tools/bin/check_test_scope_completeness");
      Append_Line (Text, "  tools/bin/check_release_consistency");
      Append_Line (Text, "  tools/bin/check_release_consistency_selftest");
      Append_Line (Text, "  tools/bin/check_release_package_selftest");
      return To_String (Text);
   end Release_Check_Text;

   function Run_Executable (Program : String) return Boolean is
      Args   : GNAT.OS_Lib.Argument_List (1 .. 0);
      Status : Integer := 0;
   begin
      if not Ada.Directories.Exists (Version.Files.To_Native_Path (Program)) then
         return False;
      end if;

      Status :=
        GNAT.OS_Lib.Spawn
          (Program_Name => Version.Files.To_Native_Path (Program),
           Args         => Args);
      return Status = 0;
   exception
      when others =>
         return False;
   end Run_Executable;

   function Run_Release_Checks return Boolean is
   begin
      return Run_Executable ("tools/bin/check_version_metadata")
        and then Run_Executable ("tools/bin/check_documentation_coherence")
        and then Run_Executable ("tools/bin/check_test_scope_completeness")
        and then Run_Executable ("tools/bin/check_release_consistency")
        and then Run_Executable ("tools/bin/check_release_consistency_selftest")
        and then Run_Executable ("tools/bin/check_release_package_selftest");
   end Run_Release_Checks;

end Version.Doctor;
