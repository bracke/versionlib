with Ada.Directories;
with Ada.Exceptions;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Files;
with Version.Init;
with Version.Objects;
with Version.Packed_Refs; use Version.Packed_Refs;
with Version.Repository;
with Version.Test_Support;

package body Version.Ref_Transaction.Tests is
   use Version.Objects;

   use AUnit.Assertions;
   use type Ada.Directories.File_Kind;

   function Join (Left, Right : String) return String renames Version.Test_Support.Join;

   Id_A : constant Version.Objects.Hex_Object_Id :=
     Version.Objects.To_Object_Id ("1111111111111111111111111111111111111111");
   Id_B : constant Version.Objects.Hex_Object_Id :=
     Version.Objects.To_Object_Id ("2222222222222222222222222222222222222222");
   Id_C : constant Version.Objects.Hex_Object_Id :=
     Version.Objects.To_Object_Id ("3333333333333333333333333333333333333333");
   Zero_Id : constant String := "0000000000000000000000000000000000000000";

   procedure With_Fresh_Repo
     (T   : in out AUnit.Test_Cases.Test_Case'Class;
      Old : out Ada.Strings.Unbounded.Unbounded_String)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
   begin
      Old := Ada.Strings.Unbounded.To_Unbounded_String
        (Ada.Directories.Current_Directory);

      Ada.Directories.Set_Directory (Root);
      Version.Init.Init (".");
   end With_Fresh_Repo;

   function Ref_Path
     (Repo : Version.Repository.Repository_Handle;
      Name : String)
      return String
   is
   begin
      return Join (Version.Repository.Git_Dir (Repo), Name);
   end Ref_Path;

   function Read_Ref_File
     (Repo : Version.Repository.Repository_Handle;
      Name : String)
      return String
   is
   begin
      return Version.Files.Read_Binary_File (Ref_Path (Repo, Name));
   end Read_Ref_File;

   function Rollback_Artifact_Exists
     (Repo : Version.Repository.Repository_Handle)
      return Boolean
   is
      function In_Tree (Path : String) return Boolean is
         Search : Ada.Directories.Search_Type;
         Item   : Ada.Directories.Directory_Entry_Type;
         Opened : Boolean := False;
      begin
         if not Ada.Directories.Exists (Path)
           or else Ada.Directories.Kind (Path) /= Ada.Directories.Directory
         then
            return False;
         end if;

         Ada.Directories.Start_Search
           (Search    => Search,
            Directory => Path,
            Pattern   => "*",
            Filter    =>
              [Ada.Directories.Ordinary_File => True,
               Ada.Directories.Directory     => True,
               Ada.Directories.Special_File  => False]);
         Opened := True;

         while Ada.Directories.More_Entries (Search) loop
            Ada.Directories.Get_Next_Entry (Search, Item);

            declare
               Name : constant String := Ada.Directories.Simple_Name (Item);
               Full : constant String := Ada.Directories.Full_Name (Item);
            begin
               if Name = "." or else Name = ".." then
                  null;
               elsif Ada.Strings.Fixed.Index (Name, ".rollback-") /= 0 then
                  Ada.Directories.End_Search (Search);
                  return True;
               elsif Ada.Directories.Kind (Item) = Ada.Directories.Directory
                 and then In_Tree (Full)
               then
                  Ada.Directories.End_Search (Search);
                  return True;
               end if;
            end;
         end loop;

         Ada.Directories.End_Search (Search);
         return False;
      exception
         when others =>
            if Opened then
               Ada.Directories.End_Search (Search);
            end if;
            raise;
      end In_Tree;
   begin
      return In_Tree (Version.Repository.Common_Git_Dir (Repo));
   end Rollback_Artifact_Exists;

   procedure Write_Ref_File
     (Repo : Version.Repository.Repository_Handle;
      Name : String;
      Id   : Version.Objects.Hex_Object_Id)
   is
   begin
      Version.Files.Write_Binary_File
        (Path    => Ref_Path (Repo, Name),
         Content => To_String (Id) & Character'Val (10));
   end Write_Ref_File;

   procedure Expect_Data_Error
     (Action  : not null access procedure;
      Message : String)
   is
      Raised : Boolean := False;
   begin
      begin
         Action.all;
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, Message);
   end Expect_Data_Error;

   procedure Update_Single_Ref
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_U : Ada.Strings.Unbounded.Unbounded_String;
   begin
      With_Fresh_Repo (T, Old_U);

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Tx   : Version.Ref_Transaction.Transaction;
      begin
         Version.Ref_Transaction.Start (Tx, Repo);
         Version.Ref_Transaction.Add_Update
           (Item     => Tx,
            Ref_Name => "refs/heads/main",
            New_Id   => Id_A);
         Version.Ref_Transaction.Commit (Tx);

         Assert
           (Read_Ref_File (Repo, "refs/heads/main") = To_String (Id_A) & Character'Val (10),
            "single ref update should write ref file");
         Assert
           (not Ada.Directories.Exists (Ref_Path (Repo, "refs/heads/main.lock")),
            "single ref update should remove lock file");
      end;

      Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
   exception
      when others =>
         Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
         raise;
   end Update_Single_Ref;

   procedure Update_Multiple_Refs
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_U : Ada.Strings.Unbounded.Unbounded_String;
   begin
      With_Fresh_Repo (T, Old_U);

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Tx   : Version.Ref_Transaction.Transaction;
      begin
         Version.Ref_Transaction.Start (Tx, Repo);
         Version.Ref_Transaction.Add_Update (Tx, "refs/heads/dev", Id_B);
         Version.Ref_Transaction.Add_Update (Tx, "refs/heads/main", Id_A);
         Version.Ref_Transaction.Commit (Tx);

         Assert
           (Read_Ref_File (Repo, "refs/heads/main") = To_String (Id_A) & Character'Val (10),
            "multi-ref update should write main");
         Assert
           (Read_Ref_File (Repo, "refs/heads/dev") = To_String (Id_B) & Character'Val (10),
            "multi-ref update should write dev");
      end;

      Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
   exception
      when others =>
         Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
         raise;
   end Update_Multiple_Refs;

   procedure Duplicate_Ref_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_U : Ada.Strings.Unbounded.Unbounded_String;

      procedure Add_Duplicate is
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Tx   : Version.Ref_Transaction.Transaction;
      begin
         Version.Ref_Transaction.Start (Tx, Repo);
         Version.Ref_Transaction.Add_Update (Tx, "refs/heads/main", Id_A);
         Version.Ref_Transaction.Add_Delete (Tx, "refs/heads/main");
      end Add_Duplicate;
   begin
      With_Fresh_Repo (T, Old_U);
      Expect_Data_Error (Add_Duplicate'Access, "duplicate ref operation should be rejected");
      Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
   exception
      when others =>
         Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
         raise;
   end Duplicate_Ref_Rejected;

   procedure Stale_Lock_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_U : Ada.Strings.Unbounded.Unbounded_String;

      procedure Commit_With_Stale_Lock is
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Tx   : Version.Ref_Transaction.Transaction;
      begin
         Version.Files.Write_Binary_File
           (Path    => Ref_Path (Repo, "refs/heads/main.lock"),
            Content => "stale" & Character'Val (10));
         Version.Ref_Transaction.Start (Tx, Repo);
         Version.Ref_Transaction.Add_Update (Tx, "refs/heads/main", Id_A);
         Version.Ref_Transaction.Commit (Tx);
      end Commit_With_Stale_Lock;
   begin
      With_Fresh_Repo (T, Old_U);
      Expect_Data_Error (Commit_With_Stale_Lock'Access,
                         "stale lock should reject commit");
      Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
   exception
      when others =>
         Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
         raise;
   end Stale_Lock_Rejected;

   procedure Expected_Old_Matches
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_U : Ada.Strings.Unbounded.Unbounded_String;
   begin
      With_Fresh_Repo (T, Old_U);

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Tx   : Version.Ref_Transaction.Transaction;
      begin
         Write_Ref_File (Repo, "refs/heads/main", Id_A);
         Version.Ref_Transaction.Start (Tx, Repo);
         Version.Ref_Transaction.Add_Update
           (Item         => Tx,
            Ref_Name     => "refs/heads/main",
            New_Id       => Id_B,
            Expected_Old => To_String (Id_A));
         Version.Ref_Transaction.Commit (Tx);

         Assert
           (Read_Ref_File (Repo, "refs/heads/main") = To_String (Id_B) & Character'Val (10),
            "matching expected old should allow update");
      end;

      Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
   exception
      when others =>
         Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
         raise;
   end Expected_Old_Matches;

   procedure Expected_Old_Mismatch_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_U : Ada.Strings.Unbounded.Unbounded_String;

      procedure Commit_Mismatch is
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Tx   : Version.Ref_Transaction.Transaction;
      begin
         Write_Ref_File (Repo, "refs/heads/main", Id_A);
         Version.Ref_Transaction.Start (Tx, Repo);
         Version.Ref_Transaction.Add_Update
           (Item         => Tx,
            Ref_Name     => "refs/heads/main",
            New_Id       => Id_C,
            Expected_Old => To_String (Id_B));
         Version.Ref_Transaction.Commit (Tx);
      end Commit_Mismatch;
   begin
      With_Fresh_Repo (T, Old_U);
      Expect_Data_Error (Commit_Mismatch'Access,
                         "expected old mismatch should reject commit");
      Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
   exception
      when others =>
         Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
         raise;
   end Expected_Old_Mismatch_Rejected;

   procedure Expected_Zero_Requires_Missing
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_U : Ada.Strings.Unbounded.Unbounded_String;

      procedure Commit_Existing_With_Zero is
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Tx   : Version.Ref_Transaction.Transaction;
      begin
         Write_Ref_File (Repo, "refs/heads/main", Id_A);
         Version.Ref_Transaction.Start (Tx, Repo);
         Version.Ref_Transaction.Add_Update
           (Item         => Tx,
            Ref_Name     => "refs/heads/main",
            New_Id       => Id_B,
            Expected_Old => Zero_Id);
         Version.Ref_Transaction.Commit (Tx);
      end Commit_Existing_With_Zero;
   begin
      With_Fresh_Repo (T, Old_U);
      Expect_Data_Error (Commit_Existing_With_Zero'Access,
                         "zero expected old should require missing ref");
      Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
   exception
      when others =>
         Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
         raise;
   end Expected_Zero_Requires_Missing;

   procedure Cancel_Removes_Locks
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_U : Ada.Strings.Unbounded.Unbounded_String;
   begin
      With_Fresh_Repo (T, Old_U);

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Tx   : Version.Ref_Transaction.Transaction;
      begin
         Version.Ref_Transaction.Start (Tx, Repo);
         Version.Ref_Transaction.Add_Update (Tx, "refs/heads/main", Id_A);
         Version.Ref_Transaction.Cancel (Tx);

         Assert
           (not Ada.Directories.Exists (Ref_Path (Repo, "refs/heads/main.lock")),
            "abort should leave no lock file");
         Assert
           (not Ada.Directories.Exists (Ref_Path (Repo, "refs/heads/main")),
            "abort before commit should not write ref file");
      end;

      Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
   exception
      when others =>
         Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
         raise;
   end Cancel_Removes_Locks;

   procedure Delete_Loose_Ref
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_U : Ada.Strings.Unbounded.Unbounded_String;
   begin
      With_Fresh_Repo (T, Old_U);

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Tx   : Version.Ref_Transaction.Transaction;
      begin
         Write_Ref_File (Repo, "refs/heads/topic", Id_A);
         Version.Ref_Transaction.Start (Tx, Repo);
         Version.Ref_Transaction.Add_Delete
           (Item         => Tx,
            Ref_Name     => "refs/heads/topic",
            Expected_Old => To_String (Id_A));
         Version.Ref_Transaction.Commit (Tx);

         Assert
           (not Ada.Directories.Exists (Ref_Path (Repo, "refs/heads/topic")),
            "delete should remove loose ref");
         Assert
           (not Ada.Directories.Exists (Ref_Path (Repo, "refs/heads/topic.lock")),
            "delete should remove lock file");
      end;

      Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
   exception
      when others =>
         Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
         raise;
   end Delete_Loose_Ref;

   procedure Deterministic_Order_Cleans_All_Locks
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_U : Ada.Strings.Unbounded.Unbounded_String;
   begin
      With_Fresh_Repo (T, Old_U);

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Tx   : Version.Ref_Transaction.Transaction;
      begin
         Version.Ref_Transaction.Start (Tx, Repo);
         Version.Ref_Transaction.Add_Update (Tx, "refs/heads/zeta", Id_C);
         Version.Ref_Transaction.Add_Update (Tx, "refs/heads/alpha", Id_A);
         Version.Ref_Transaction.Add_Update (Tx, "refs/heads/mid", Id_B);
         Version.Ref_Transaction.Commit (Tx);

         Assert
           (Read_Ref_File (Repo, "refs/heads/alpha") = To_String (Id_A) & Character'Val (10),
            "deterministic transaction should write alpha");
         Assert
           (Read_Ref_File (Repo, "refs/heads/mid") = To_String (Id_B) & Character'Val (10),
            "deterministic transaction should write mid");
         Assert
           (Read_Ref_File (Repo, "refs/heads/zeta") = To_String (Id_C) & Character'Val (10),
            "deterministic transaction should write zeta");
         Assert
           (not Ada.Directories.Exists (Ref_Path (Repo, "refs/heads/alpha.lock"))
            and then not Ada.Directories.Exists (Ref_Path (Repo, "refs/heads/mid.lock"))
            and then not Ada.Directories.Exists (Ref_Path (Repo, "refs/heads/zeta.lock")),
            "deterministic transaction should clean all locks");
         Assert
           (not Ada.Directories.Exists (Ref_Path (Repo, "refs/heads/alpha.rollback"))
            and then not Ada.Directories.Exists (Ref_Path (Repo, "refs/heads/mid.rollback"))
            and then not Ada.Directories.Exists (Ref_Path (Repo, "refs/heads/zeta.rollback")),
            "deterministic transaction should clean all legacy rollback files");
         Assert
           (not Rollback_Artifact_Exists (Repo),
            "deterministic transaction should clean generated rollback files");
      end;

      Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
   exception
      when others =>
         Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
         raise;
   end Deterministic_Order_Cleans_All_Locks;

   procedure Invalid_Ref_Name_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_U : Ada.Strings.Unbounded.Unbounded_String;

      procedure Add_Invalid is
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Tx   : Version.Ref_Transaction.Transaction;
      begin
         Version.Ref_Transaction.Start (Tx, Repo);
         Version.Ref_Transaction.Add_Update (Tx, "../refs/heads/main", Id_A);
      end Add_Invalid;
   begin
      With_Fresh_Repo (T, Old_U);
      Expect_Data_Error (Add_Invalid'Access, "invalid ref name should be rejected");
      Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
   exception
      when others =>
         Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
         raise;
   end Invalid_Ref_Name_Rejected;

   procedure Packed_Delete_Rolls_Back_When_Later_Update_Fails
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_U : Ada.Strings.Unbounded.Unbounded_String;

      procedure Commit_With_Later_Rollback_Failure is
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Tx   : Version.Ref_Transaction.Transaction;
      begin
         Version.Ref_Transaction.Start (Tx, Repo);
         Version.Ref_Transaction.Add_Delete
           (Item         => Tx,
            Ref_Name     => "refs/heads/alpha-packed",
            Expected_Old => To_String (Id_A));
         Version.Ref_Transaction.Add_Update
           (Item     => Tx,
            Ref_Name => "refs/heads/zeta-loose/sub",
            New_Id   => Id_C);
         Version.Ref_Transaction.Commit (Tx);
      end Commit_With_Later_Rollback_Failure;
   begin
      With_Fresh_Repo (T, Old_U);

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Refs : Version.Packed_Refs.Packed_Ref_Vectors.Vector;
         Id   : Version.Objects.Object_Id_Storage := Version.Objects.Zero_Object_Id;
      begin
         Refs.Append
           (Packed_Ref'
              (Name =>
                 Ada.Strings.Unbounded.To_Unbounded_String
                   ("refs/heads/alpha-packed"),
               Id   => Id_A));
         Version.Packed_Refs.Write_All (Repo, Refs);
         Version.Files.Write_Binary_File
           (Path    => Ref_Path (Repo, "refs/heads/zeta-loose"),
            Content => To_String (Id_B) & Character'Val (10));

         Expect_Data_Error
           (Commit_With_Later_Rollback_Failure'Access,
            "later loose path conflict should reject mixed transaction");

         Assert
           (Version.Packed_Refs.Find
              (Repo => Repo,
               Name => "refs/heads/alpha-packed",
               Id   => Id),
            "failed mixed transaction must restore deleted packed ref");
         Assert (Id = Id_A,
                 "failed mixed transaction must restore packed ref id");
         Assert
           (Read_Ref_File (Repo, "refs/heads/zeta-loose")
            = To_String (Id_B) & Character'Val (10),
            "failed mixed transaction must preserve later loose ref");
         Assert
           (not Ada.Directories.Exists
              (Ref_Path (Repo, "refs/heads/alpha-packed.lock"))
            and then not Ada.Directories.Exists
              (Ref_Path (Repo, "refs/heads/zeta-loose/sub.lock")),
            "failed mixed transaction must clean lock files");
         Assert
           (not Rollback_Artifact_Exists (Repo),
            "failed mixed transaction must clean generated rollback files");
      end;

      Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
   exception
      when others =>
         Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
         raise;
   end Packed_Delete_Rolls_Back_When_Later_Update_Fails;

   procedure Generated_Rollback_Collision_Is_Skipped
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_U : Ada.Strings.Unbounded.Unbounded_String;
   begin
      With_Fresh_Repo (T, Old_U);

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Tx   : Version.Ref_Transaction.Transaction;
      begin
         Write_Ref_File (Repo, "refs/heads/main", Id_A);
         Version.Files.Write_Binary_File
           (Path    => Ref_Path (Repo, "refs/heads/main.rollback-1"),
            Content => "stale generated rollback" & Character'Val (10));

         Version.Ref_Transaction.Start (Tx, Repo);
         Version.Ref_Transaction.Add_Update (Tx, "refs/heads/main", Id_B);
         Version.Ref_Transaction.Commit (Tx);

         Assert
           (Read_Ref_File (Repo, "refs/heads/main")
            = To_String (Id_B) & Character'Val (10),
            "generated rollback collision must not block ref update");
         Assert
           (Ada.Directories.Exists
              (Ref_Path (Repo, "refs/heads/main.rollback-1")),
            "pre-existing generated rollback collision should be left untouched");
         Assert
           (not Ada.Directories.Exists
              (Ref_Path (Repo, "refs/heads/main.rollback-2")),
            "allocated rollback collision fallback must be cleaned");
         Version.Files.Delete_File_If_Exists
           (Ref_Path (Repo, "refs/heads/main.rollback-1"));
      end;

      Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
   exception
      when others =>
         Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
         raise;
   end Generated_Rollback_Collision_Is_Skipped;

   procedure Legacy_Rollback_File_Is_Cleaned
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_U : Ada.Strings.Unbounded.Unbounded_String;
   begin
      With_Fresh_Repo (T, Old_U);

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Tx   : Version.Ref_Transaction.Transaction;
      begin
         Write_Ref_File (Repo, "refs/heads/main", Id_A);
         Version.Files.Write_Binary_File
           (Path    => Ref_Path (Repo, "refs/heads/main.rollback"),
            Content => "stale" & Character'Val (10));

         Version.Ref_Transaction.Start (Tx, Repo);
         Version.Ref_Transaction.Add_Update (Tx, "refs/heads/main", Id_B);
         Version.Ref_Transaction.Commit (Tx);

         Assert
           (Read_Ref_File (Repo, "refs/heads/main")
            = To_String (Id_B) & Character'Val (10),
            "legacy rollback file must not block ref update");
         Assert
           (not Ada.Directories.Exists
              (Ref_Path (Repo, "refs/heads/main.rollback")),
            "legacy rollback file must be cleaned");
         Assert
           (not Ada.Directories.Exists
              (Ref_Path (Repo, "refs/heads/main.lock")),
            "legacy rollback cleanup must leave no lock file");
         Assert
           (not Rollback_Artifact_Exists (Repo),
            "legacy rollback cleanup must leave no generated rollback files");
      end;

      Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
   exception
      when others =>
         Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
         raise;
   end Legacy_Rollback_File_Is_Cleaned;

   procedure Ref_Path_Conflict_Preserves_Earlier_Refs
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_U : Ada.Strings.Unbounded.Unbounded_String;

      procedure Commit_With_Path_Conflict is
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Tx   : Version.Ref_Transaction.Transaction;
      begin
         Version.Files.Write_Binary_File
           (Path    => Ref_Path (Repo, "refs/heads/conflict"),
            Content => To_String (Id_A) & Character'Val (10));
         Version.Ref_Transaction.Start (Tx, Repo);
         Version.Ref_Transaction.Add_Update (Tx, "refs/heads/aaa", Id_B);
         Version.Ref_Transaction.Add_Update (Tx, "refs/heads/conflict/sub", Id_C);
         Version.Ref_Transaction.Commit (Tx);
      end Commit_With_Path_Conflict;
   begin
      With_Fresh_Repo (T, Old_U);
      Expect_Data_Error
        (Commit_With_Path_Conflict'Access,
         "ref path conflict should reject commit");

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
      begin
         Assert
           (not Ada.Directories.Exists (Ref_Path (Repo, "refs/heads/aaa")),
            "path conflict must not leave earlier sorted ref update");
         Assert
           (Read_Ref_File (Repo, "refs/heads/conflict")
            = To_String (Id_A) & Character'Val (10),
            "path conflict must preserve existing conflicting ref");
      end;

      Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
   exception
      when others =>
         Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
         raise;
   end Ref_Path_Conflict_Preserves_Earlier_Refs;

   procedure Expected_Old_Reads_Packed_Ref
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_U : Ada.Strings.Unbounded.Unbounded_String;
   begin
      With_Fresh_Repo (T, Old_U);

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Refs : Version.Packed_Refs.Packed_Ref_Vectors.Vector;
         Tx   : Version.Ref_Transaction.Transaction;
      begin
         Refs.Append
           (Packed_Ref'(Name => Ada.Strings.Unbounded.To_Unbounded_String ("refs/heads/main"),
             Id   => Id_A));
         Version.Packed_Refs.Write_All (Repo, Refs);

         Version.Ref_Transaction.Start (Tx, Repo);
         Version.Ref_Transaction.Add_Update
           (Item         => Tx,
            Ref_Name     => "refs/heads/main",
            New_Id       => Id_B,
            Expected_Old => To_String (Id_A));
         Version.Ref_Transaction.Commit (Tx);

         Assert
           (Read_Ref_File (Repo, "refs/heads/main") = To_String (Id_B) & Character'Val (10),
            "expected old should read packed refs");
      end;

      Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
   exception
      when others =>
         Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
         raise;
   end Expected_Old_Reads_Packed_Ref;

   procedure Loose_Overrides_Packed_Expected_Old
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_U : Ada.Strings.Unbounded.Unbounded_String;
   begin
      With_Fresh_Repo (T, Old_U);

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Refs : Version.Packed_Refs.Packed_Ref_Vectors.Vector;
         Tx   : Version.Ref_Transaction.Transaction;
      begin
         Refs.Append
           (Packed_Ref'(Name => Ada.Strings.Unbounded.To_Unbounded_String ("refs/heads/main"),
             Id   => Id_A));
         Version.Packed_Refs.Write_All (Repo, Refs);
         Write_Ref_File (Repo, "refs/heads/main", Id_B);

         Version.Ref_Transaction.Start (Tx, Repo);
         Version.Ref_Transaction.Add_Update
           (Item         => Tx,
            Ref_Name     => "refs/heads/main",
            New_Id       => Id_C,
            Expected_Old => To_String (Id_B));
         Version.Ref_Transaction.Commit (Tx);

         Assert
           (Read_Ref_File (Repo, "refs/heads/main") = To_String (Id_C) & Character'Val (10),
            "loose ref should override packed ref for expected old");
      end;

      Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
   exception
      when others =>
         Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
         raise;
   end Loose_Overrides_Packed_Expected_Old;

   procedure Delete_Packed_Only_Ref
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_U : Ada.Strings.Unbounded.Unbounded_String;
   begin
      With_Fresh_Repo (T, Old_U);

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Refs : Version.Packed_Refs.Packed_Ref_Vectors.Vector;
         Tx   : Version.Ref_Transaction.Transaction;
         Id   : Version.Objects.Object_Id_Storage := Version.Objects.Zero_Object_Id;
      begin
         Refs.Append
           (Packed_Ref'(Name => Ada.Strings.Unbounded.To_Unbounded_String ("refs/heads/main"),
             Id   => Id_A));
         Version.Packed_Refs.Write_All (Repo, Refs);

         Version.Ref_Transaction.Start (Tx, Repo);
         Version.Ref_Transaction.Add_Delete
           (Item         => Tx,
            Ref_Name     => "refs/heads/main",
            Expected_Old => To_String (Id_A));
         Version.Ref_Transaction.Commit (Tx);

         Assert
           (not Version.Packed_Refs.Find (Repo => Repo, Name => "refs/heads/main", Id => Id),
            "packed-only delete should remove packed ref");
         Assert
           (not Ada.Directories.Exists (Ref_Path (Repo, "refs/heads/main")),
            "packed-only delete should not create loose ref");
         Assert
           (not Ada.Directories.Exists (Ref_Path (Repo, "refs/heads/main.lock")),
            "packed-only delete should remove lock file");
      end;

      Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
   exception
      when others =>
         Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
         raise;
   end Delete_Packed_Only_Ref;

   procedure Delete_Loose_Override_And_Packed_Ref
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_U : Ada.Strings.Unbounded.Unbounded_String;
   begin
      With_Fresh_Repo (T, Old_U);

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Refs : Version.Packed_Refs.Packed_Ref_Vectors.Vector;
         Tx   : Version.Ref_Transaction.Transaction;
         Id   : Version.Objects.Object_Id_Storage := Version.Objects.Zero_Object_Id;
      begin
         Refs.Append
           (Packed_Ref'(Name => Ada.Strings.Unbounded.To_Unbounded_String ("refs/heads/main"),
             Id   => Id_A));
         Version.Packed_Refs.Write_All (Repo, Refs);
         Write_Ref_File (Repo, "refs/heads/main", Id_B);

         Version.Ref_Transaction.Start (Tx, Repo);
         Version.Ref_Transaction.Add_Delete
           (Item         => Tx,
            Ref_Name     => "refs/heads/main",
            Expected_Old => To_String (Id_B));
         Version.Ref_Transaction.Commit (Tx);

         Assert
           (not Version.Packed_Refs.Find (Repo => Repo, Name => "refs/heads/main", Id => Id),
            "delete should remove packed ref behind loose override");
         Assert
           (not Ada.Directories.Exists (Ref_Path (Repo, "refs/heads/main")),
            "delete should remove loose override");
      end;

      Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
   exception
      when others =>
         Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
         raise;
   end Delete_Loose_Override_And_Packed_Ref;

   procedure Delete_Packed_Expected_Old_Mismatch_Preserves_Refs
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_U : Ada.Strings.Unbounded.Unbounded_String;

      procedure Delete_With_Mismatch is
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Tx   : Version.Ref_Transaction.Transaction;
      begin
         Version.Ref_Transaction.Start (Tx, Repo);
         Version.Ref_Transaction.Add_Delete
           (Item         => Tx,
            Ref_Name     => "refs/heads/main",
            Expected_Old => To_String (Id_B));
         Version.Ref_Transaction.Commit (Tx);
      end Delete_With_Mismatch;
   begin
      With_Fresh_Repo (T, Old_U);

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Refs : Version.Packed_Refs.Packed_Ref_Vectors.Vector;
         Id   : Version.Objects.Object_Id_Storage := Version.Objects.Zero_Object_Id;
      begin
         Refs.Append
           (Packed_Ref'(Name => Ada.Strings.Unbounded.To_Unbounded_String ("refs/heads/main"),
             Id   => Id_A));
         Version.Packed_Refs.Write_All (Repo, Refs);
         Write_Ref_File (Repo, "refs/heads/main", Id_C);

         Expect_Data_Error
           (Delete_With_Mismatch'Access,
            "packed ref delete expected-old mismatch should reject");

         Assert
           (Version.Packed_Refs.Find (Repo => Repo, Name => "refs/heads/main", Id => Id),
            "expected-old mismatch should preserve packed ref");
         Assert (Id = Id_A, "expected-old mismatch should preserve packed id");
         Assert
           (Read_Ref_File (Repo, "refs/heads/main") = To_String (Id_C) & Character'Val (10),
            "expected-old mismatch should preserve loose ref");
      end;

      Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
   exception
      when others =>
         Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
         raise;
   end Delete_Packed_Expected_Old_Mismatch_Preserves_Refs;

   procedure Rename_Style_Branch_Delete_Rejects_Stale_Source
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_U : Ada.Strings.Unbounded.Unbounded_String;
   begin
      With_Fresh_Repo (T, Old_U);

      declare
         Repo   : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Tx     : Version.Ref_Transaction.Transaction;
         Raised : Boolean := False;
      begin
         Write_Ref_File (Repo, "refs/heads/feature", Id_B);

         begin
            Version.Ref_Transaction.Start (Tx, Repo);
            Version.Ref_Transaction.Add_Update
              (Item         => Tx,
               Ref_Name     => "refs/heads/topic",
               New_Id       => Id_A,
               Expected_Old => Zero_Id);
            Version.Ref_Transaction.Add_Delete
              (Item         => Tx,
               Ref_Name     => "refs/heads/feature",
               Expected_Old => To_String (Id_A));
            Version.Ref_Transaction.Commit (Tx);
         exception
            when E : Ada.IO_Exceptions.Data_Error =>
               Raised := True;
               Assert
                 (Ada.Exceptions.Exception_Message (E)
                  = Expected_Old_Mismatch_Diagnostic ("refs/heads/feature"),
                  "branch rename-style stale delete diagnostic changed: "
                  & Ada.Exceptions.Exception_Message (E));
               Version.Ref_Transaction.Cancel (Tx);
         end;

         Assert (Raised, "stale branch source delete must be rejected");
         Assert
           (Read_Ref_File (Repo, "refs/heads/feature") = To_String (Id_B) & Character'Val (10),
            "stale branch source delete must preserve changed source ref");
         Assert
           (not Ada.Directories.Exists (Ref_Path (Repo, "refs/heads/topic")),
            "stale branch source delete must not create destination ref");
         Assert
           (not Ada.Directories.Exists (Ref_Path (Repo, "refs/heads/feature.lock"))
            and then not Ada.Directories.Exists (Ref_Path (Repo, "refs/heads/topic.lock")),
            "stale branch source delete must clean transaction locks");
         Assert
           (not Rollback_Artifact_Exists (Repo),
            "stale branch source delete must not leave rollback artifacts");
      end;

      Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
   exception
      when others =>
         Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
         raise;
   end Rename_Style_Branch_Delete_Rejects_Stale_Source;

   procedure Rename_Style_Tag_Delete_Rejects_Missing_Source
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_U : Ada.Strings.Unbounded.Unbounded_String;
   begin
      With_Fresh_Repo (T, Old_U);

      declare
         Repo   : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Tx     : Version.Ref_Transaction.Transaction;
         Raised : Boolean := False;
      begin
         begin
            Version.Ref_Transaction.Start (Tx, Repo);
            Version.Ref_Transaction.Add_Update
              (Item         => Tx,
               Ref_Name     => "refs/tags/new",
               New_Id       => Id_A,
               Expected_Old => Zero_Id);
            Version.Ref_Transaction.Add_Delete
              (Item         => Tx,
               Ref_Name     => "refs/tags/old",
               Expected_Old => To_String (Id_A));
            Version.Ref_Transaction.Commit (Tx);
         exception
            when E : Ada.IO_Exceptions.Data_Error =>
               Raised := True;
               Assert
                 (Ada.Exceptions.Exception_Message (E)
                  = Expected_Old_Mismatch_Diagnostic ("refs/tags/old"),
                  "tag rename-style missing delete diagnostic changed: "
                  & Ada.Exceptions.Exception_Message (E));
               Version.Ref_Transaction.Cancel (Tx);
         end;

         Assert (Raised, "missing tag source delete must be rejected");
         Assert
           (not Ada.Directories.Exists (Ref_Path (Repo, "refs/tags/old")),
            "missing tag source delete must keep source ref missing");
         Assert
           (not Ada.Directories.Exists (Ref_Path (Repo, "refs/tags/new")),
            "missing tag source delete must not create destination ref");
         Assert
           (not Ada.Directories.Exists (Ref_Path (Repo, "refs/tags/old.lock"))
            and then not Ada.Directories.Exists (Ref_Path (Repo, "refs/tags/new.lock")),
            "missing tag source delete must clean transaction locks");
         Assert
           (not Rollback_Artifact_Exists (Repo),
            "missing tag source delete must not leave rollback artifacts");
      end;

      Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
   exception
      when others =>
         Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
         raise;
   end Rename_Style_Tag_Delete_Rejects_Missing_Source;

   overriding procedure Register_Tests (T : in out Test_Case) is
   begin
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Update_Single_Ref'Access,
         "Ref transaction updates single ref");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Update_Multiple_Refs'Access,
         "Ref transaction updates multiple refs");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Duplicate_Ref_Rejected'Access,
         "Ref transaction rejects duplicate ref operation");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Stale_Lock_Rejected'Access,
         "Ref transaction rejects stale lock");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Expected_Old_Matches'Access,
         "Ref transaction expected old matches");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Expected_Old_Mismatch_Rejected'Access,
         "Ref transaction expected old mismatch rejects");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Expected_Zero_Requires_Missing'Access,
         "Ref transaction expected zero requires missing ref");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Cancel_Removes_Locks'Access,
         "Ref transaction abort removes lock files");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Delete_Loose_Ref'Access,
         "Ref transaction deletes loose ref");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Delete_Packed_Only_Ref'Access,
         "Ref transaction deletes packed-only ref");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Delete_Loose_Override_And_Packed_Ref'Access,
         "Ref transaction deletes loose override and packed ref");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Delete_Packed_Expected_Old_Mismatch_Preserves_Refs'Access,
         "Ref transaction packed delete expected-old mismatch preserves refs");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Rename_Style_Branch_Delete_Rejects_Stale_Source'Access,
         "Ref transaction rename-style branch delete rejects stale source");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Rename_Style_Tag_Delete_Rejects_Missing_Source'Access,
         "Ref transaction rename-style tag delete rejects missing source");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Deterministic_Order_Cleans_All_Locks'Access,
         "Ref transaction deterministic order cleans locks");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Invalid_Ref_Name_Rejected'Access,
         "Ref transaction rejects invalid ref name");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Legacy_Rollback_File_Is_Cleaned'Access,
         "Ref transaction cleans legacy rollback file");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Generated_Rollback_Collision_Is_Skipped'Access,
         "Ref transaction skips generated rollback collision");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Packed_Delete_Rolls_Back_When_Later_Update_Fails'Access,
         "Ref transaction packed delete rolls back on later failure");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Ref_Path_Conflict_Preserves_Earlier_Refs'Access,
         "Ref transaction path conflict preserves earlier refs");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Expected_Old_Reads_Packed_Ref'Access,
         "Ref transaction expected old reads packed ref");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Loose_Overrides_Packed_Expected_Old'Access,
         "Ref transaction loose overrides packed expected old");
   end Register_Tests;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Ref_Transaction");
   end Name;

end Version.Ref_Transaction.Tests;
