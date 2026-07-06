with Ada.Directories;
with Ada.IO_Exceptions;
with AUnit.Assertions;
with AUnit.Test_Cases;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

with Version.Branch;
with Version.Files;
with Version.Git_Fixtures;
with Version.Init;
with Version.Objects;
with Version.Repository;
with Version.Refs;
with Version.Restore;
with Version.Staging;
with Version.Sparse;
with Version.Test_Support;
with Version.Write;

package body Version.Worktrees.Tests is

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

   procedure Create_File (Root : String; Path : String; Content : String) is
      Full : constant String := Version.Test_Support.Join (Root, Path);
   begin
      Version.Files.Create_Parent_Directories (Full);
      Version.Test_Support.Write_Text_File (Full, Content);
   end Create_File;

   function Prepare_Repo
     (T : in out AUnit.Test_Cases.Test_Case'Class) return String
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run
        (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");
      Create_File (Root, "a.txt", "a" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add .");
      Ada.Directories.Set_Directory (Root);
      Version.Write.Save ("initial");
      Version.Branch.Create_Branch ("feature");
      return Root;
   end Prepare_Repo;

   function Contains_Worktree
     (Items : Version.Worktrees.Worktree_Info_Vectors.Vector; Path : String)
      return Boolean is
   begin
      if Items.Is_Empty then
         return False;
      end if;

      for I in Items.First_Index .. Items.Last_Index loop
         if To_String (Items.Element (I).Path) = Path then
            return True;
         end if;
      end loop;
      return False;
   end Contains_Worktree;

   procedure Add_List_And_Remove_Linked_Worktree
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String := Prepare_Repo (T);
      Work : constant String := Root & "-feature";
   begin
      Version.Worktrees.Add (Path => Work, Branch => "feature");
      Assert
        (Version.Files.Is_Ordinary_File (Version.Files.Join (Work, ".git")),
         "linked worktree must contain .git indirection file");
      Assert
        (Contains_Worktree (Version.Worktrees.List, Work),
         "worktree list must include linked path");
      Assert
        (Version.Files.Is_Ordinary_File
           (Version.Files.Join
              (Version.Repository.Resolve_Git_Dir (Work), "index")),
         "linked worktree must have independent index file");
      Version.Worktrees.Remove (Work);
      Assert
        (not Ada.Directories.Exists (Version.Files.To_Native_Path (Work)),
         "remove should delete linked working tree");
   end Add_List_And_Remove_Linked_Worktree;

   procedure Branch_Occupancy_Is_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root   : constant String := Prepare_Repo (T);
      Work   : constant String := Root & "-feature";
      Other  : constant String := Root & "-feature2";
      Raised : Boolean := False;
   begin
      Version.Worktrees.Add (Path => Work, Branch => "feature");
      begin
         Version.Worktrees.Add (Path => Other, Branch => "feature");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;
      Assert (Raised, "same branch must not be checked out twice");
      Version.Worktrees.Remove (Work);
   end Branch_Occupancy_Is_Rejected;

   procedure Dirty_Remove_Is_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root   : constant String := Prepare_Repo (T);
      Work   : constant String := Root & "-feature";
      Raised : Boolean := False;
   begin
      Version.Worktrees.Add (Path => Work, Branch => "feature");
      Create_File (Work, "dirty.txt", "dirty" & Character'Val (10));
      begin
         Version.Worktrees.Remove (Work);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;
      Assert (Raised, "dirty linked worktree removal must be rejected");
      Version.Files.Delete_File_If_Exists
        (Version.Files.Join (Work, "dirty.txt"));
      Version.Worktrees.Remove (Work);
   end Dirty_Remove_Is_Rejected;

   procedure Sparse_State_Is_Per_Worktree
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root  : constant String := Prepare_Repo (T);
      Work  : constant String := Root & "-feature";
      Items : Version.Sparse.String_Vectors.Vector;
   begin
      Version.Worktrees.Add (Path => Work, Branch => "feature");
      Items.Append ("a.txt");
      declare
         procedure Set_Linked_Sparse is
            Repo : constant Version.Repository.Repository_Handle :=
              Version.Repository.Open;
         begin
            Version.Sparse.Set_From_Strings (Repo, Items);
            Assert
              (Version.Sparse.Enabled (Repo),
               "linked sparse state should be enabled");
         end Set_Linked_Sparse;

         procedure Check_Primary_Sparse is
            Repo : constant Version.Repository.Repository_Handle :=
              Version.Repository.Open;
         begin
            Assert
              (not Version.Sparse.Enabled (Repo),
               "primary sparse file must remain independent");
         end Check_Primary_Sparse;
      begin
         Version.Files.With_Directory (Work, Set_Linked_Sparse'Access);
         Version.Files.With_Directory (Root, Check_Primary_Sparse'Access);
      end;
      Version.Worktrees.Remove (Work);
   end Sparse_State_Is_Per_Worktree;

   procedure Restore_In_Linked_Worktree_Does_Not_Touch_Primary
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String := Prepare_Repo (T);
      Work : constant String := Root & "-feature";

      procedure Restore_Linked is
      begin
         Version.Test_Support.Write_Text_File
           (Version.Test_Support.Join (Work, "a.txt"),
            "linked dirty" & Character'Val (10));
         Version.Restore.Restore_Path ("a.txt");
      end Restore_Linked;
   begin
      Version.Worktrees.Add (Path => Work, Branch => "feature");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "a.txt"),
         "primary dirty" & Character'Val (10));

      Version.Files.With_Directory (Work, Restore_Linked'Access);

      Assert
        (Version.Test_Support.Read_Text_File
           (Version.Test_Support.Join (Work, "a.txt"))
         = "a",
         "restore in linked worktree must restore the linked worktree file");
      Assert
        (Version.Test_Support.Read_Text_File
           (Version.Test_Support.Join (Root, "a.txt"))
         = "primary dirty",
         "restore in linked worktree must not touch the primary working tree");

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "a.txt"), "a" & Character'Val (10));
      Version.Worktrees.Remove (Work);
   end Restore_In_Linked_Worktree_Does_Not_Touch_Primary;

   procedure Detached_Worktree_Is_Allowed
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root           : constant String := Prepare_Repo (T);
      Work           : constant String := Root & "-detached";
      Found_Detached : Boolean := False;
   begin
      Version.Worktrees.Add_Detached (Path => Work, Rev => "HEAD");

      declare
         Items : constant Version.Worktrees.Worktree_Info_Vectors.Vector :=
           Version.Worktrees.List;
      begin
         if not Items.Is_Empty then
            for I in Items.First_Index .. Items.Last_Index loop
               if To_String (Items.Element (I).Path) = Work
                 and then Items.Element (I).Detached
               then
                  Found_Detached := True;
               end if;
            end loop;
         end if;
      end;

      Assert (Found_Detached, "detached worktree must be listed as detached");
      Version.Worktrees.Remove (Work);
   end Detached_Worktree_Is_Allowed;

   procedure Branch_Switch_Isolation_Is_Enforced
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root   : constant String := Prepare_Repo (T);
      Work   : constant String := Root & "-feature";
      Raised : Boolean := False;
   begin
      Version.Worktrees.Add (Path => Work, Branch => "feature");
      begin
         Version.Branch.Switch_Branch ("feature");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert
        (Raised,
         "branch switch must reject a branch checked out in a linked worktree");
      Version.Worktrees.Remove (Work);
   end Branch_Switch_Isolation_Is_Enforced;

   procedure Index_State_Is_Per_Worktree
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String := Prepare_Repo (T);
      Work : constant String := Root & "-feature";

      procedure Stage_Linked_Only is
         Repo    : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Entries : Version.Staging.Index_Entry_Vectors.Vector :=
           Version.Staging.Load (Repo);
         Blob    : constant Version.Objects.Hex_Object_Id :=
           Version.Write.Write_Blob (Repo, "linked" & Character'Val (10));
      begin
         Version.Staging.Replace_Entry
           (Entries,
            (Path  => To_Unbounded_String ("linked-only.txt"),
             Id    => Blob,
             Mode  => To_Unbounded_String ("100644"),
             Stage => 0));
         Version.Staging.Write (Repo, Entries);
      end Stage_Linked_Only;

      procedure Check_Primary_Index is
         Repo    : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Entries : constant Version.Staging.Index_Entry_Vectors.Vector :=
           Version.Staging.Load (Repo);
      begin
         Assert
           (Version.Staging.Find_Path (Entries, "linked-only.txt")
            = Natural'Last,
            "primary index must not include entries staged in linked worktree");
      end Check_Primary_Index;

      procedure Reset_Linked_Index is
         Repo   : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Commit : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         Version.Restore.Write_Index_For_Commit
           (Repo => Repo, Commit_Id => Version.Objects.To_Object_Id (Commit));
      end Reset_Linked_Index;
   begin
      Version.Worktrees.Add (Path => Work, Branch => "feature");
      Version.Files.With_Directory (Work, Stage_Linked_Only'Access);
      Version.Files.With_Directory (Root, Check_Primary_Index'Access);
      Version.Files.With_Directory (Work, Reset_Linked_Index'Access);
      Version.Worktrees.Remove (Work);
   end Index_State_Is_Per_Worktree;

   procedure Remove_Rejects_Common_Dir_Mismatch
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root   : constant String := Prepare_Repo (T);
      Work   : constant String := Root & "-feature";
      Admin  : Unbounded_String;
      Raised : Boolean := False;
   begin
      Version.Worktrees.Add (Path => Work, Branch => "feature");
      Admin := To_Unbounded_String (Version.Repository.Resolve_Git_Dir (Work));

      Version.Files.Write_Binary_File
        (Path    => Version.Files.Join (To_String (Admin), "commondir"),
         Content => "../../.." & Character'Val (10));

      begin
         Version.Worktrees.Remove (Work);
      exception
         when Ada.IO_Exceptions.Data_Error | Ada.Directories.Name_Error =>
            Raised := True;
      end;

      Assert
        (Raised,
         "remove must reject linked worktrees whose commondir no longer matches the caller repository");

      Version.Files.Write_Binary_File
        (Path    => Version.Files.Join (To_String (Admin), "commondir"),
         Content => "../.." & Character'Val (10));
      Version.Worktrees.Remove (Work);
   end Remove_Rejects_Common_Dir_Mismatch;

   procedure List_Ignores_Mismatched_Admin_Backlink
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root       : constant String := Prepare_Repo (T);
      Repo       : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
      Fake_Work  : constant String := Root & "-fake";
      Fake_Admin : constant String :=
        Version.Files.Join
          (Version.Files.Join
             (Version.Repository.Common_Git_Dir (Repo), "worktrees"),
           "fake");
   begin
      Ada.Directories.Create_Path (Version.Files.To_Native_Path (Fake_Work));
      Ada.Directories.Create_Path (Version.Files.To_Native_Path (Fake_Admin));
      Version.Files.Write_Binary_File
        (Path    => Version.Files.Join (Fake_Admin, "HEAD"),
         Content => "ref: refs/heads/feature" & Character'Val (10));
      Version.Files.Write_Binary_File
        (Path    => Version.Files.Join (Fake_Admin, "gitdir"),
         Content =>
           Version.Files.Join (Fake_Work, ".git") & Character'Val (10));
      Version.Files.Write_Binary_File
        (Path    => Version.Files.Join (Fake_Admin, "commondir"),
         Content => "../.." & Character'Val (10));

      Assert
        (not Contains_Worktree (Version.Worktrees.List, Fake_Work),
         "list must ignore admin entries whose target .git file does not point back");

      Ada.Directories.Delete_Tree (Version.Files.To_Native_Path (Fake_Admin));
      Ada.Directories.Delete_Tree (Version.Files.To_Native_Path (Fake_Work));
   end List_Ignores_Mismatched_Admin_Backlink;

   procedure Malformed_Git_File_Is_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root   : constant String := Prepare_Repo (T);
      Bad    : constant String := Root & "-bad";
      Raised : Boolean := False;
   begin
      Ada.Directories.Create_Path (Version.Files.To_Native_Path (Bad));
      Version.Files.Write_Binary_File
        (Path    => Version.Files.Join (Bad, ".git"),
         Content => "gitdir: ../../escape" & Character'Val (10));

      begin
         declare
            Value : constant String :=
              Version.Repository.Resolve_Git_Dir (Bad);
         begin
            if Value'Length > 0 then
               Raised := False;
            end if;
         end;
      exception
         when Ada.Directories.Name_Error | Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "malformed .git indirection must be rejected");
   end Malformed_Git_File_Is_Rejected;

   procedure Worktree_Status_Display_Labels
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      Primary  : constant Version.Worktrees.Worktree_Info :=
        (Path     => To_Unbounded_String ("/repo"),
         Branch   => To_Unbounded_String ("main"),
         Detached => False,
         Current  => True,
         Missing  => False);
      Linked   : constant Version.Worktrees.Worktree_Info :=
        (Path     => To_Unbounded_String ("/repo-feature"),
         Branch   => To_Unbounded_String ("feature"),
         Detached => False,
         Current  => False,
         Missing  => False);
      Missing  : constant Version.Worktrees.Worktree_Info :=
        (Path     => To_Unbounded_String ("/repo-missing"),
         Branch   => To_Unbounded_String ("feature"),
         Detached => False,
         Current  => False,
         Missing  => True);
      Detached : constant Version.Worktrees.Worktree_Info :=
        (Path     => To_Unbounded_String ("/repo-detached"),
         Branch   => To_Unbounded_String ("1234567890abcdef"),
         Detached => True,
         Current  => False,
         Missing  => False);
   begin
      Assert
        (Version.Worktrees.Worktree_Status_Line (Primary)
         = "/repo [current primary] branch main",
         "primary worktree status line must be stable");
      Assert
        (Version.Worktrees.Worktree_Status_Line (Linked)
         = "/repo-feature [linked branch-in-use] branch feature",
         "linked branch worktree status line must mark branch in use");
      Assert
        (Version.Worktrees.Worktree_Status_Line (Missing)
         = "/repo-missing [linked missing branch-in-use] branch feature",
         "missing linked worktree status line must be stable");
      Assert
        (Version.Worktrees.Worktree_Status_Line (Detached)
         = "/repo-detached [linked detached] detached 1234567890ab",
         "detached linked worktree status line must use short object id");
   end Worktree_Status_Display_Labels;

   procedure Current_Worktree_Text_Identifies_Primary_And_Linked
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String := Prepare_Repo (T);
      Work : constant String := Root & "-current";

      procedure Check_Linked is
      begin
         Assert
           (Version.Worktrees.Current_Worktree_Text
            = Work & " [current linked] branch feature" & Character'Val (10),
            "current linked worktree text must identify linked worktree");
      end Check_Linked;
   begin
      Assert
        (Version.Worktrees.Current_Worktree_Text
         = Root & " [current primary] branch main" & Character'Val (10),
         "current primary worktree text must identify primary worktree");

      Version.Worktrees.Add (Path => Work, Branch => "feature");
      Version.Files.With_Directory (Work, Check_Linked'Access);
   end Current_Worktree_Text_Identifies_Primary_And_Linked;

   procedure Missing_Linked_Worktree_Is_Listed
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root  : constant String := Prepare_Repo (T);
      Work  : constant String := Root & "-missing";
      Admin : Unbounded_String;
      Found : Boolean := False;
   begin
      Version.Worktrees.Add (Path => Work, Branch => "feature");
      Admin := To_Unbounded_String (Version.Repository.Resolve_Git_Dir (Work));
      Ada.Directories.Delete_Tree (Version.Files.To_Native_Path (Work));

      declare
         Items : constant Version.Worktrees.Worktree_Info_Vectors.Vector :=
           Version.Worktrees.List;
      begin
         if not Items.Is_Empty then
            for I in Items.First_Index .. Items.Last_Index loop
               declare
                  Item : constant Version.Worktrees.Worktree_Info :=
                    Items.Element (I);
               begin
                  if To_String (Item.Path) = Work then
                     Found :=
                       Item.Missing
                       and then
                         Version.Worktrees.Worktree_Status_Line (Item)
                         = Work
                           & " [linked missing branch-in-use] branch feature";
                  end if;
               end;
            end loop;
         end if;
      end;

      Assert
        (Found,
         "worktree list must preserve and label missing linked worktrees");
      Version.Files.Delete_Directory_Tree_If_Exists (To_String (Admin));
   end Missing_Linked_Worktree_Is_Listed;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
   begin
      Register_Routine
        (T,
         Add_List_And_Remove_Linked_Worktree'Access,
         "Worktree: add/list/remove linked worktree");
      Register_Routine
        (T,
         Branch_Occupancy_Is_Rejected'Access,
         "Worktree: branch occupancy rejection");
      Register_Routine
        (T,
         Dirty_Remove_Is_Rejected'Access,
         "Worktree: dirty removal rejected");
      Register_Routine
        (T,
         Sparse_State_Is_Per_Worktree'Access,
         "Worktree: sparse state isolated");
      Register_Routine
        (T,
         Restore_In_Linked_Worktree_Does_Not_Touch_Primary'Access,
         "Worktree: restore in linked worktree is isolated");
      Register_Routine
        (T,
         Detached_Worktree_Is_Allowed'Access,
         "Worktree: detached worktree allowed");
      Register_Routine
        (T,
         Worktree_Status_Display_Labels'Access,
         "Worktree: status display labels");
      Register_Routine
        (T,
         Current_Worktree_Text_Identifies_Primary_And_Linked'Access,
         "Worktree: current worktree text identifies primary and linked");
      Register_Routine
        (T,
         Missing_Linked_Worktree_Is_Listed'Access,
         "Worktree: missing linked status listed");
      Register_Routine
        (T,
         Branch_Switch_Isolation_Is_Enforced'Access,
         "Worktree: branch switch isolated");
      Register_Routine
        (T,
         Index_State_Is_Per_Worktree'Access,
         "Worktree: index state isolated");
      Register_Routine
        (T,
         Remove_Rejects_Common_Dir_Mismatch'Access,
         "Worktree: remove rejects commondir mismatch");
      Register_Routine
        (T,
         List_Ignores_Mismatched_Admin_Backlink'Access,
         "Worktree: list ignores mismatched admin backlink");
      Register_Routine
        (T,
         Malformed_Git_File_Is_Rejected'Access,
         "Worktree: malformed .git indirection rejected");
   end Register_Tests;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Worktrees.Tests");
   end Name;

end Version.Worktrees.Tests;
