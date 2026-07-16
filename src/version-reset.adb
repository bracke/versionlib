with Version.Objects;
with Version.Ref_Names;
with Version.Ref_Transaction;
with Version.Reflog;
with Version.Refs;
with Version.Restore;
with Version.Revisions;
with Version.Staging;
with Version.Tree_Cache;

package body Version.Reset is
   use Version.Objects;

   use Ada.Strings.Unbounded;

   --  Move the current branch (or detached HEAD) to Commit with a reflog entry,
   --  rolling the branch back on a post-move failure. Mirrors the fail-before-
   --  mutation HEAD-advance used by save.
   procedure Move_Head
     (Repo    : Version.Repository.Repository_Handle;
      Commit  : Version.Objects.Hex_Object_Id;
      Old_Id  : String;
      Message : String)
   is
      Head : constant Version.Refs.Head_Info := Version.Refs.Read_Head (Repo);
   begin
      if Version.Refs.Is_Attached (Head) then
         declare
            Branch_Name  : constant String := Version.Refs.Branch_Name (Head);
            Branch_Ref   : constant String := "refs/heads/" & Branch_Name;
            Branch_Moved : Boolean := False;

            procedure Write_Branch
              (To : Version.Objects.Hex_Object_Id; Expected_Old : String)
            is
               Tx : Version.Ref_Transaction.Transaction;
            begin
               Version.Ref_Transaction.Start (Tx, Repo);
               Version.Ref_Transaction.Add_Update
                 (Item         => Tx,
                  Ref_Name     => Branch_Ref,
                  New_Id       => To,
                  Expected_Old => Expected_Old);
               Version.Ref_Transaction.Commit (Tx);
            exception
               when others =>
                  Version.Ref_Transaction.Cancel (Tx);
                  raise;
            end Write_Branch;
         begin
            Version.Ref_Names.Require_Branch_Name (Branch_Name);
            Version.Ref_Names.Require_Ref_Name (Branch_Ref);
            Version.Reflog.Preflight_Append
              (Repo, "HEAD", Version.Reflog.Data_Error_On_Lock);
            Version.Reflog.Preflight_Append
              (Repo, Branch_Ref, Version.Reflog.Data_Error_On_Lock);

            Write_Branch (Commit, Old_Id);
            Branch_Moved := True;

            Version.Reflog.Append
              (Repo, "HEAD", Old_Id, To_String (Commit), Message);
            Version.Reflog.Append
              (Repo, Branch_Ref, Old_Id, To_String (Commit), Message);
         exception
            when others =>
               if Branch_Moved then
                  begin
                     Write_Branch
                       (Version.Objects.To_Object_Id (Old_Id), To_String (Commit));
                  exception
                     when others =>
                        null;
                  end;
               end if;
               raise;
         end;
      else
         Version.Reflog.Preflight_Append
           (Repo, "HEAD", Version.Reflog.Data_Error_On_Lock);
         Version.Refs.Write_Detached_HEAD
           (Repo         => Repo,
            Commit_Id    => Commit,
            Expected_Old => Version.Objects.To_Object_Id (Old_Id));
         Version.Reflog.Append
           (Repo, "HEAD", Old_Id, To_String (Commit), Message);
      end if;
   end Move_Head;

   procedure Reset_To_Commit
     (Repo   : Version.Repository.Repository_Handle;
      Mode   : Reset_Mode;
      Target : String)
   is
      --  Resolve before any mutation (fail-before-mutation).
      Commit : constant Version.Objects.Hex_Object_Id :=
        Version.Revisions.Resolve_Commit (Repo, Target);
      Old_Id : constant String := Version.Refs.Current_Commit_Id (Repo);
   begin
      if Mode = Hard then
         Version.Restore.Preflight_Working_Tree_For_Commit (Repo, Commit);
      end if;

      Move_Head (Repo, Commit, Old_Id, "reset: moving to " & Target);

      --  Reset the working tree first (it prunes paths using the still-current
      --  index, i.e. the pre-reset tree), then reset the index to the target.
      if Mode = Hard then
         Version.Restore.Restore_Working_Tree_For_Commit (Repo, Commit);
      end if;

      if Mode = Mixed or else Mode = Hard then
         Version.Restore.Write_Index_For_Commit (Repo, Commit);
      end if;
   end Reset_To_Commit;

   procedure Reset_Paths
     (Repo   : Version.Repository.Repository_Handle;
      Target : String;
      Paths  : Path_Vectors.Vector)
   is
      --  Resolve before any mutation (fail-before-mutation).
      Commit      : constant Version.Objects.Hex_Object_Id :=
        Version.Revisions.Resolve_Commit (Repo, Target);
      Commit_Obj  : constant Version.Objects.Git_Object :=
        Version.Objects.Read_Object (Repo, Commit);
      Tree_Id     : constant Version.Objects.Hex_Object_Id :=
        Version.Objects.Commit_Tree_Id (Commit_Obj);
      Cache       : Version.Tree_Cache.Tree_Cache;
      Flat        : constant Version.Objects.Tree_Entry_Vectors.Vector :=
        Version.Tree_Cache.Flatten_Tree (Repo, Cache, Tree_Id);
      Idx         : Version.Staging.Index_Entry_Vectors.Vector :=
        Version.Staging.Load (Repo);

      function Matches (Path, Spec : String) return Boolean is
      begin
         if Spec = "" or else Spec = "." or else Spec = ":/" then
            return True;
         end if;
         if Path = Spec then
            return True;
         end if;
         return Path'Length > Spec'Length
           and then Path (Path'First .. Path'First + Spec'Length - 1) = Spec
           and then Path (Path'First + Spec'Length) = '/';
      end Matches;

      function Matches_Any (Path : String) return Boolean is
      begin
         for Spec of Paths loop
            if Matches (Path, To_String (Spec)) then
               return True;
            end if;
         end loop;
         return False;
      end Matches_Any;

      function In_Tree (Path : String) return Boolean is
      begin
         for E of Flat loop
            if E.Kind /= Version.Objects.Tree_Directory
              and then To_String (E.Path) = Path
            then
               return True;
            end if;
         end loop;
         return False;
      end In_Tree;

      To_Remove : Path_Vectors.Vector;
   begin
      --  1. For each target-tree entry under the pathspecs, set the index entry.
      for E of Flat loop
         if E.Kind /= Version.Objects.Tree_Directory
           and then Matches_Any (To_String (E.Path))
         then
            Version.Staging.Replace_Entry
              (Idx,
               (Path  => E.Path,
                Id    => E.Id,
                Mode  => E.Mode,
                Stage => 0, Skip_Worktree => False));
         end if;
      end loop;

      --  2. Drop index entries under the pathspecs that are absent from the tree.
      for E of Idx loop
         if Matches_Any (To_String (E.Path))
           and then not In_Tree (To_String (E.Path))
         then
            To_Remove.Append (E.Path);
         end if;
      end loop;
      for P of To_Remove loop
         Version.Staging.Remove_Path (Idx, To_String (P));
      end loop;

      Version.Staging.Sort_By_Path (Idx);
      Version.Staging.Write (Repo, Idx);
   end Reset_Paths;

end Version.Reset;
