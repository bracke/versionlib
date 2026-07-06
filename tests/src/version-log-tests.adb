with Ada.Directories;
with Ada.Strings.Fixed;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Git_Fixtures;
with Version.Objects;
with Version.Repository;
with Version.Ref_Cache;
with Version.Test_Support;

package body Version.Log.Tests is

   use AUnit.Assertions;

   function Contains (Text : String; Fragment : String) return Boolean is
   begin
      return Ada.Strings.Fixed.Index (Text, Fragment) /= 0;
   end Contains;

   function Starts_With (Text : String; Prefix : String) return Boolean is
   begin
      return Text'Length >= Prefix'Length
        and then Text (Text'First .. Text'First + Prefix'Length - 1) = Prefix;
   end Starts_With;

   procedure Log_Prints_Head_Commit
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      Ada.Directories.Set_Directory (Root);
      declare
         Text : constant String := Version.Log.Log_Head (Version.Repository.Open);
      begin
         Assert (Contains (Text, "commit "), "commit line missing");
         Assert (Contains (Text, "Author: Test <test@example.com>"), "author missing");
         Assert (Contains (Text, "initial"), "subject missing");
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Log_Prints_Head_Commit;

   procedure Log_Oneline_Prints_Short_Id_And_Subject
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      Ada.Directories.Set_Directory (Root);
      declare
         Repo    : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Refs    : Version.Ref_Cache.Ref_Cache;
         Full_Id : constant String :=
           Version.Ref_Cache.Current_Commit_Id (Repo => Repo, Cache => Refs);
         Text    : constant String := Version.Log.Log_Oneline_Head (Repo);
      begin
         Assert
           (Starts_With (Text, Full_Id (Full_Id'First .. Full_Id'First + 11) & " initial"),
            "oneline log must begin with short id and subject");
         Assert
           (not Contains (Text, "commit "),
            "oneline log must not use full log commit header");
         Assert
           (not Contains (Text, "Author:"),
            "oneline log must not include author header");
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Log_Oneline_Prints_Short_Id_And_Subject;

   procedure Log_Oneline_From_Revision_Uses_Same_Walk
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "b.txt"),
         "second" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add b.txt && git commit -m second");

      Ada.Directories.Set_Directory (Root);
      declare
         Repo    : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Refs    : Version.Ref_Cache.Ref_Cache;
         Full_Id : constant String :=
           Version.Ref_Cache.Current_Commit_Id (Repo => Repo, Cache => Refs);
         Text    : constant String :=
           Version.Log.Log_Oneline_From_Commit
             (Repo, Version.Objects.To_Object_Id (Full_Id));
      begin
         Assert (Contains (Text, " second"), "newest subject missing");
         Assert (Contains (Text, " initial"), "parent subject missing");
         Assert
           (Ada.Strings.Fixed.Index (Text, " second")
            < Ada.Strings.Fixed.Index (Text, " initial"),
            "oneline log must keep newest-to-oldest walk order");
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Log_Oneline_From_Revision_Uses_Same_Walk;

   overriding procedure Register_Tests
     (T : in out Test_Case)
   is
   begin
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Log_Prints_Head_Commit'Access, "Log: prints HEAD commit");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Log_Oneline_Prints_Short_Id_And_Subject'Access,
         "Log: oneline prints short id and subject");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Log_Oneline_From_Revision_Uses_Same_Walk'Access,
         "Log: oneline from revision uses same walk");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Log");
   end Name;

end Version.Log.Tests;
