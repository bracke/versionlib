with Ada.Directories;
with Ada.Exceptions;
with Ada.IO_Exceptions;
with Ada.Strings.Unbounded;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Git_Fixtures;
with Version.Objects;
with Version.Refs;
with Version.Repository;
with Version.Staging;
with Version.Test_Support;
with Version.Write;
with Version.Init;

package body Version.History.Tests is

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

   function Contains_Object
     (Items : Version.Objects.Object_Id_Vectors.Vector;
      Id    : Version.Objects.Hex_Object_Id)
      return Boolean
   is
   begin
      if Items.Is_Empty then
         return False;
      end if;

      for I in Items.First_Index .. Items.Last_Index loop
         if Items.Element (I) = Id then
            return True;
         end if;
      end loop;

      return False;
   end Contains_Object;

   procedure Linear_History_Ancestor_And_Merge_Base
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
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");

      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (File_Path,
         "one" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("one");

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;

         Commit_A : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id
             (Version.Refs.Current_Commit_Id (Repo));
      begin
         Version.Test_Support.Write_Text_File
           (File_Path,
            "two" & Character'Val (10));

         Version.Git_Fixtures.Run (Root, "git add a.txt");
         Version.Write.Save ("two");

         declare
            Commit_B : constant Version.Objects.Hex_Object_Id :=
              Version.Objects.To_Object_Id
                (Version.Refs.Current_Commit_Id (Repo));
         begin
            Version.Test_Support.Write_Text_File
              (File_Path,
               "three" & Character'Val (10));

            Version.Git_Fixtures.Run (Root, "git add a.txt");
            Version.Write.Save ("three");

            declare
               Commit_C : constant Version.Objects.Hex_Object_Id :=
                 Version.Objects.To_Object_Id
                   (Version.Refs.Current_Commit_Id (Repo));
            begin
               Assert
                 (Version.History.Is_Ancestor
                    (Repo       => Repo,
                     Base_Id    => Commit_A,
                     Derived_Id => Commit_C),
                  "A must be ancestor of C");

               Assert
                 (Version.History.Is_Ancestor
                    (Repo       => Repo,
                     Base_Id    => Commit_B,
                     Derived_Id => Commit_C),
                  "B must be ancestor of C");

               Assert
                 (not Version.History.Is_Ancestor
                    (Repo       => Repo,
                     Base_Id    => Commit_C,
                     Derived_Id => Commit_A),
                  "C must not be ancestor of A");

               Assert
                 (Version.History.Merge_Base
                    (Repo  => Repo,
                     Left  => Commit_B,
                     Right => Commit_C) = Commit_B,
                  "merge-base(B,C) must be B");

               Assert
                 (Version.History.Merge_Base
                    (Repo  => Repo,
                     Left  => Commit_A,
                     Right => Commit_C) = Commit_A,
                  "merge-base(A,C) must be A");

               declare
                  Reachable : constant Version.Objects.Object_Id_Vectors.Vector :=
                    Version.History.Reachable_Objects
                      (Repo    => Repo,
                       Root_Id => Commit_C);
               begin
                  Assert
                    (Contains_Object (Reachable, Commit_A),
                     "reachable objects must include first commit");
                  Assert
                    (Contains_Object (Reachable, Commit_B),
                     "reachable objects must include second commit");
                  Assert
                    (Contains_Object (Reachable, Commit_C),
                     "reachable objects must include tip commit");
               end;
            end;
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Linear_History_Ancestor_And_Merge_Base;

   procedure Merge_Base_Rejects_Unrelated_Histories
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         A_Blob : constant Version.Objects.Hex_Object_Id :=
           Version.Write.Write_Blob (Repo, "a" & Character'Val (10));
         B_Blob : constant Version.Objects.Hex_Object_Id :=
           Version.Write.Write_Blob (Repo, "b" & Character'Val (10));
         A_Entries : Version.Staging.Index_Entry_Vectors.Vector;
         B_Entries : Version.Staging.Index_Entry_Vectors.Vector;
      begin
         A_Entries.Append
           (Version.Staging.Index_Entry'(Path => Ada.Strings.Unbounded.To_Unbounded_String ("a.txt"),
             Id   => A_Blob,
             Mode => Ada.Strings.Unbounded.To_Unbounded_String ("100644"),
             Stage => 0, Skip_Worktree => False));
         B_Entries.Append
           (Version.Staging.Index_Entry'(Path => Ada.Strings.Unbounded.To_Unbounded_String ("b.txt"),
             Id   => B_Blob,
             Mode => Ada.Strings.Unbounded.To_Unbounded_String ("100644"),
             Stage => 0, Skip_Worktree => False));

         declare
            A_Tree : constant Version.Objects.Hex_Object_Id :=
              Version.Write.Write_Tree_From_Index (Repo, A_Entries);
            B_Tree : constant Version.Objects.Hex_Object_Id :=
              Version.Write.Write_Tree_From_Index (Repo, B_Entries);
            A_Commit : constant Version.Objects.Hex_Object_Id :=
              Version.Write.Write_Commit (Repo, A_Tree, "", "root a");
            B_Commit : constant Version.Objects.Hex_Object_Id :=
              Version.Write.Write_Commit (Repo, B_Tree, "", "root b");
            Raised : Boolean := False;
         begin
            begin
               declare
                  Ignored : constant Version.Objects.Hex_Object_Id :=
                    Version.History.Merge_Base (Repo, A_Commit, B_Commit);
               begin
                  pragma Unreferenced (Ignored);
               end;
            exception
               when E : Ada.IO_Exceptions.Data_Error =>
                  Raised := True;
                  Assert
                    (Ada.Exceptions.Exception_Message (E) = "no merge base found",
                     "unrelated histories must preserve no-merge-base diagnostic");
            end;

            Assert (Raised, "unrelated histories must raise Data_Error");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Base_Rejects_Unrelated_Histories;

   overriding procedure Register_Tests
     (T : in out Test_Case)
   is
   begin
      Register_Routine
        (T,
         Linear_History_Ancestor_And_Merge_Base'Access,
         "History: linear ancestry and merge base");

      Register_Routine
        (T,
         Merge_Base_Rejects_Unrelated_Histories'Access,
         "History: merge base rejects unrelated histories");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.History");
   end Name;

end Version.History.Tests;