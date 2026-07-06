with Version.Hooks;
with Version.Ref_Names;
with Version.Ref_Transaction;
with Version.Reflog;
with Version.Refs;
with Version.Restore;

package body Version.Replay_Finalization is
   use Version.Objects;

   procedure Write_Branch_Ref
     (Repo         : Version.Repository.Repository_Handle;
      Branch_Ref   : String;
      Commit_Id    : Version.Objects.Hex_Object_Id;
      Expected_Old : Version.Objects.Hex_Object_Id)
   is
      Tx : Version.Ref_Transaction.Transaction;
   begin
      Version.Ref_Names.Require_Ref_Name (Branch_Ref);

      Version.Ref_Transaction.Start (Tx, Repo);
      Version.Ref_Transaction.Add_Update
        (Item         => Tx,
         Ref_Name     => Branch_Ref,
         New_Id       => Commit_Id,
         Expected_Old => To_String (Expected_Old));
      Version.Ref_Transaction.Commit (Tx);
   exception
      when others =>
         Version.Ref_Transaction.Cancel (Tx);
         raise;
   end Write_Branch_Ref;

   procedure Advance_Head
     (Repo     : Version.Repository.Repository_Handle;
      Kind     : Head_Kind;
      Head_Ref : String;
      Old_Head : Version.Objects.Hex_Object_Id;
      New_Head : Version.Objects.Hex_Object_Id;
      Message  : String)
   is
      Head_Moved : Boolean := False;

      procedure Roll_Back_Worktree is
      begin
         begin
            Version.Restore.Restore_Working_Tree_For_Commit
              (Repo => Repo, Commit_Id => Old_Head);
            Version.Restore.Write_Index_For_Commit
              (Repo => Repo, Commit_Id => Old_Head);
         exception
            when others =>
               null;
         end;
      end Roll_Back_Worktree;

      procedure Roll_Back_Head is
      begin
         if Head_Moved then
            begin
               case Kind is
                  when Symbolic_Head =>
                     Write_Branch_Ref
                       (Repo         => Repo,
                        Branch_Ref   => Head_Ref,
                        Commit_Id    => Old_Head,
                        Expected_Old => New_Head);
                  when Detached_Head =>
                     Version.Refs.Write_Detached_HEAD
                       (Repo         => Repo,
                        Commit_Id    => Old_Head,
                        Expected_Old => New_Head);
               end case;
            exception
               when others =>
                  null;
            end;
         end if;
      end Roll_Back_Head;
   begin
      Version.Reflog.Preflight_Append
        (Repo, "HEAD", Version.Reflog.Use_Error_On_Lock);
      case Kind is
         when Symbolic_Head =>
            Version.Ref_Names.Require_Ref_Name (Head_Ref);
            Version.Reflog.Preflight_Append
              (Repo, Head_Ref, Version.Reflog.Use_Error_On_Lock);
         when Detached_Head =>
            null;
      end case;

      case Kind is
         when Symbolic_Head =>
            Write_Branch_Ref
              (Repo         => Repo,
               Branch_Ref   => Head_Ref,
               Commit_Id    => New_Head,
               Expected_Old => Old_Head);
            Head_Moved := True;
            Version.Reflog.Append
              (Repo    => Repo,
               Ref     => "HEAD",
               Old_Id  => To_String (Old_Head),
               New_Id  => To_String (New_Head),
               Message => Message);
            Version.Reflog.Append
              (Repo    => Repo,
               Ref     => Head_Ref,
               Old_Id  => To_String (Old_Head),
               New_Id  => To_String (New_Head),
               Message => Message);
         when Detached_Head =>
            Version.Refs.Write_Detached_HEAD
              (Repo         => Repo,
               Commit_Id    => New_Head,
               Expected_Old => Old_Head);
            Head_Moved := True;
            Version.Reflog.Append
              (Repo    => Repo,
               Ref     => "HEAD",
               Old_Id  => To_String (Old_Head),
               New_Id  => To_String (New_Head),
               Message => Message);
      end case;

      Version.Restore.Restore_Working_Tree_For_Commit
        (Repo => Repo, Commit_Id => New_Head);
      Version.Restore.Write_Index_For_Commit
        (Repo => Repo, Commit_Id => New_Head);
      Version.Hooks.Run_Post_Commit (Repo => Repo, Run_Hooks => True);
   exception
      when others =>
         Roll_Back_Worktree;
         Roll_Back_Head;
         raise;
   end Advance_Head;

end Version.Replay_Finalization;
