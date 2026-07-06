with Ada.Directories;
with Ada.Strings.Unbounded;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Objects;
with Version.Repository;
with Version.Test_Support;
with Version.Init;
with Version.Merge; use Version.Merge;

package body Version.Merge_State.Tests is
   use Version.Objects;

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

   procedure Write_Read_Clear_State
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String :=
        Ada.Directories.Current_Directory;

      Current_Id : constant Version.Objects.Hex_Object_Id :=
      Version.Objects.To_Object_Id
         ("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");

      Target_Id : constant Version.Objects.Hex_Object_Id :=
      Version.Objects.To_Object_Id
         ("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
   begin
      Version.Init.Init (Root);

      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;

         Read_Current : Version.Objects.Object_Id_Storage;
         Read_Target  : Version.Objects.Object_Id_Storage;
         Read_Branch  : Ada.Strings.Unbounded.Unbounded_String;
      begin
         Assert
           (not Version.Merge_State.State_Exists (Repo),
            "merge state must not exist initially");

         Version.Merge_State.Write_State
           (Repo          => Repo,
            Current_Id    => Current_Id,
            Target_Id     => Target_Id,
            Target_Branch => "feature");

         Assert
           (Version.Merge_State.State_Exists (Repo),
            "merge state must exist after write");

         Version.Merge_State.Read_State
           (Repo          => Repo,
            Current_Id    => Read_Current,
            Target_Id     => Read_Target,
            Target_Branch => Read_Branch);

         Assert
           (Read_Current = Current_Id,
            "current parent id mismatch");

         Assert
           (Read_Target = Target_Id,
            "target parent id mismatch");

         Assert
           (Ada.Strings.Unbounded.To_String (Read_Branch) = "feature",
            "target branch mismatch");

         Version.Merge_State.Clear_State (Repo);

         Assert
           (not Version.Merge_State.State_Exists (Repo),
            "merge state must not exist after clear");
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Write_Read_Clear_State;

   procedure Write_Read_Versioned_State_With_Conflicts
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String :=
        Ada.Directories.Current_Directory;

      Current_Id : constant Version.Objects.Hex_Object_Id :=
        Version.Objects.To_Object_Id
          ("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");

      Target_Id : constant Version.Objects.Hex_Object_Id :=
        Version.Objects.To_Object_Id
          ("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");

      Base_Id : constant Version.Objects.Hex_Object_Id :=
        Version.Objects.To_Object_Id
          ("cccccccccccccccccccccccccccccccccccccccc");

      Conflicts : Version.Merge.Conflict_Vectors.Vector;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;

         Read_Current : Version.Objects.Object_Id_Storage;
         Read_Target  : Version.Objects.Object_Id_Storage;
         Read_Base    : Version.Objects.Object_Id_Storage;
         Read_Branch  : Ada.Strings.Unbounded.Unbounded_String;
         Read_Conflicts : Version.Merge.Conflict_Vectors.Vector;
      begin
         Conflicts.Append
           (Version.Merge.Conflict'
              (Path => Ada.Strings.Unbounded.To_Unbounded_String ("a.txt"),
               Kind => Version.Merge.Content_Conflict));
         Conflicts.Append
           (Version.Merge.Conflict'
              (Path => Ada.Strings.Unbounded.To_Unbounded_String ("bin.dat"),
               Kind => Version.Merge.Binary_Conflict));

         Version.Merge_State.Write_State
           (Repo          => Repo,
            Current_Id    => Current_Id,
            Target_Id     => Target_Id,
            Base_Id       => Base_Id,
            Target_Branch => "feature",
            Conflicts     => Conflicts);

         Version.Merge_State.Read_State
           (Repo          => Repo,
            Current_Id    => Read_Current,
            Target_Id     => Read_Target,
            Base_Id       => Read_Base,
            Target_Branch => Read_Branch,
            Conflicts     => Read_Conflicts);

         Assert (Read_Current = Current_Id, "current parent id mismatch");
         Assert (Read_Target = Target_Id, "target parent id mismatch");
         Assert (Read_Base = Base_Id, "base id mismatch");
         Assert
           (Ada.Strings.Unbounded.To_String (Read_Branch) = "feature",
            "target branch mismatch");
         Assert (Natural (Read_Conflicts.Length) = 2, "conflict count mismatch");
         Assert
           (Read_Conflicts.Element (Read_Conflicts.First_Index).Kind
            = Version.Merge.Content_Conflict,
            "first conflict kind mismatch");
         Assert
           (Ada.Strings.Unbounded.To_String
              (Read_Conflicts.Element (Read_Conflicts.Last_Index).Path)
            = "bin.dat",
            "second conflict path mismatch");
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Write_Read_Versioned_State_With_Conflicts;

   procedure Read_Old_Three_Line_State
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String :=
        Ada.Directories.Current_Directory;

      Current_Id : constant Version.Objects.Hex_Object_Id :=
        Version.Objects.To_Object_Id
          ("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");

      Target_Id : constant Version.Objects.Hex_Object_Id :=
        Version.Objects.To_Object_Id
          ("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, ".git/VERSION_MERGE"),
         To_String (Current_Id) & Character'Val (10)
         & To_String (Target_Id) & Character'Val (10)
         & "feature" & Character'Val (10));

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;

         Read_Current : Version.Objects.Object_Id_Storage;
         Read_Target  : Version.Objects.Object_Id_Storage;
         Read_Base    : Version.Objects.Object_Id_Storage;
         Read_Branch  : Ada.Strings.Unbounded.Unbounded_String;
         Read_Conflicts : Version.Merge.Conflict_Vectors.Vector;
      begin
         Version.Merge_State.Read_State
           (Repo          => Repo,
            Current_Id    => Read_Current,
            Target_Id     => Read_Target,
            Base_Id       => Read_Base,
            Target_Branch => Read_Branch,
            Conflicts     => Read_Conflicts);

         Assert (Read_Current = Current_Id, "old current parent id mismatch");
         Assert (Read_Target = Target_Id, "old target parent id mismatch");
         Assert
           (To_String (Read_Base) = "0000000000000000000000000000000000000000",
            "old merge state must synthesize a null base id");
         Assert
           (Ada.Strings.Unbounded.To_String (Read_Branch) = "feature",
            "old target branch mismatch");
         Assert
           (Read_Conflicts.Is_Empty,
            "old merge state must not synthesize conflicts");
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Read_Old_Three_Line_State;

   overriding procedure Register_Tests
     (T : in out Test_Case)
   is
   begin
      Register_Routine
        (T,
         Write_Read_Clear_State'Access,
         "Merge state: write read clear");

      Register_Routine
        (T,
         Write_Read_Versioned_State_With_Conflicts'Access,
         "Merge state: write read versioned conflicts");

      Register_Routine
        (T,
         Read_Old_Three_Line_State'Access,
         "Merge state: read old three-line state");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Merge_State");
   end Name;

end Version.Merge_State.Tests;