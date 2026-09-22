with Ada.Containers.Indefinite_Ordered_Sets;
with Ada.Containers.Vectors;
with Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;

with Version.Files;
with Version.Hash;
with Version.History;
with Version.Merge;
with Version.Ref_Names;
with Version.Ref_Transaction;
with Version.Reflog;
with Version.Refs;
with Version.Revisions;
with Version.Write;

package body Version.Notes_Merge is
   use Version.Objects;
   use Version.Notes;

   LF : constant Character := Character'Val (10);

   Partial_Ref   : constant String := "NOTES_MERGE_PARTIAL";
   Merge_Ref     : constant String := "NOTES_MERGE_REF";
   Worktree_Name : constant String := "NOTES_MERGE_WORKTREE";

   function Parse_Strategy
     (Text : String; Result : out Strategy) return Boolean is
   begin
      if Text = "manual" then
         Result := Manual;
      elsif Text = "ours" then
         Result := Ours;
      elsif Text = "theirs" then
         Result := Theirs;
      elsif Text = "union" then
         Result := Union;
      elsif Text = "cat_sort_uniq" then
         Result := Cat_Sort_Uniq;
      else
         Result := Manual;
         return False;
      end if;
      return True;
   end Parse_Strategy;

   function Worktree_Path
     (Repo : Version.Repository.Repository_Handle) return String is
      pragma Unreferenced (Repo);
   begin
      --  git prints the git-dir-relative path whatever the current directory.
      return ".git/" & Worktree_Name;
   end Worktree_Path;

   function Worktree_Dir
     (Repo : Version.Repository.Repository_Handle) return String is
     (Version.Files.Join (Version.Repository.Git_Dir (Repo), Worktree_Name));

   function State_File
     (Repo : Version.Repository.Repository_Handle; Name : String) return String
   is (Version.Files.Join (Version.Repository.Git_Dir (Repo), Name));

   --  A state file's content without surrounding whitespace or newlines
   --  (Ada.Strings.Fixed.Trim only drops spaces).
   function Trimmed (Text : String) return String is
      First : Positive := Text'First;
      Last  : Natural := Text'Last;
   begin
      while First <= Last and then Text (First) in ' ' | ASCII.HT | LF | ASCII.CR
      loop
         First := First + 1;
      end loop;
      while Last >= First and then Text (Last) in ' ' | ASCII.HT | LF | ASCII.CR
      loop
         Last := Last - 1;
      end loop;
      return Text (First .. Last);
   end Trimmed;

   procedure Say (Output : in out Unbounded_String; Line : String) is
   begin
      Append (Output, Line);
      Append (Output, LF);
   end Say;

   function Short (Id : String) return String is
     (Id (Id'First .. Id'First + 6));

   --  A commit's tree as a notes map; an empty id (no merge base) is the
   --  empty tree.
   procedure Load_Tree
     (Repo   : Version.Repository.Repository_Handle;
      Commit : String;
      Tree   : out Notes_Tree) is
   begin
      if Commit'Length = 0 then
         Tree := Empty_Tree ("");
      else
         Load_From_Commit (Repo, To_Object_Id (Commit), "", Tree);
      end if;
   end Load_Tree;

   --  git's lookup_commit_reference: the commit an id names, peeling tags;
   --  "" when it is not a commit at all.
   function Commit_Of
     (Repo : Version.Repository.Repository_Handle; Id : String) return String is
   begin
      return To_String (Version.Revisions.Resolve_Commit (Repo, Id));
   exception
      when Ada.IO_Exceptions.Data_Error =>
         return "";
   end Commit_Of;

   --  A note blob's content ("" for no note).
   function Note_Text
     (Repo : Version.Repository.Repository_Handle; Id : String) return String is
   begin
      if Id'Length = 0 then
         return "";
      end if;
      return Version.Objects.Content
        (Version.Objects.Read_Object (Repo, To_Object_Id (Id)));
   end Note_Text;

   ---------------------------------------------------------------------------
   --  The worktree

   --  git's check_notes_merge_worktree: the first conflict establishes the
   --  worktree, refusing when a previous merge's files are still there.
   procedure Establish_Worktree
     (Repo         : Version.Repository.Repository_Handle;
      Has_Worktree : in out Boolean)
   is
      Dir : constant String := Worktree_Dir (Repo);
   begin
      if Has_Worktree then
         if not Version.Files.Exists (Dir) then
            raise Notes_Error with
              "missing '" & Dir & "'. This should not happen";
         end if;
         return;
      end if;

      if Version.Files.Exists (Dir) then
         declare
            Search : Ada.Directories.Search_Type;
            Empty  : Boolean := True;
         begin
            Ada.Directories.Start_Search (Search, Dir, "");
            while Ada.Directories.More_Entries (Search) loop
               declare
                  Item : Ada.Directories.Directory_Entry_Type;
               begin
                  Ada.Directories.Get_Next_Entry (Search, Item);
                  if Ada.Directories.Simple_Name (Item) not in "." | ".." then
                     Empty := False;
                  end if;
               end;
            end loop;
            Ada.Directories.End_Search (Search);
            if not Empty then
               --  The full two-line text is Unconcluded_Merge_Message; an
               --  exception message would be truncated.
               raise Notes_Error with Unconcluded_Merge_Key;
            end if;
         end;
      end if;

      Version.Files.Create_Directory_If_Missing (Dir);
      Has_Worktree := True;
   end Establish_Worktree;

   procedure Write_To_Worktree
     (Repo : Version.Repository.Repository_Handle; Object, Text : String)
   is
      Path : constant String := Version.Files.Join (Worktree_Dir (Repo), Object);
   begin
      if Version.Files.Exists (Path) then
         raise Notes_Error with
           "unable to create '" & Path & "': File exists";
      end if;
      Version.Files.Write_Binary_File (Path, Text);
   end Write_To_Worktree;

   ---------------------------------------------------------------------------
   --  Merging

   --  git's notes_merge_pair.
   type Change is record
      Object : Unbounded_String;
      Base   : Unbounded_String;   --  "" when absent in the base
      Local  : Unbounded_String;   --  "" when absent locally
      Remote : Unbounded_String;   --  "" when removed remotely
      Local_Set : Boolean := False;   --  git's "uninitialized" sentinel
   end record;

   package Change_Vectors is new Ada.Containers.Vectors (Positive, Change);

   --  git's merge_from_diffs: the remote's changes against the base, with
   --  the local side's state of each, then resolved one by one.
   procedure Merge_From_Diffs
     (Repo         : Version.Repository.Repository_Handle;
      Options      : in out Merge_Options;
      Base, Remote : Notes_Tree;
      Result       : in out Notes_Tree;
      Conflicts    : out Natural;
      Output       : in out Unbounded_String;
      Warnings     : in out Version.Ref_Format.String_Vectors.Vector)
   is
      package Key_Sets is new Ada.Containers.Indefinite_Ordered_Sets (String);
      Changes      : Change_Vectors.Vector;
      Has_Worktree : Boolean := False;
      Local_Ref    : constant String := To_String (Options.Local_Ref);
      Remote_Ref   : constant String := To_String (Options.Remote_Ref);

      --  git's diff_tree_remote: every object whose note differs between
      --  base and remote.
      procedure Collect_Remote_Changes is
         Keys : Key_Sets.Set;
      begin
         for E of Entries (Base) loop
            Keys.Include (To_String (E.Commit));
         end loop;
         for E of Entries (Remote) loop
            Keys.Include (To_String (E.Commit));
         end loop;
         for K of Keys loop
            declare
               B : constant String := Note_Of (Base, K);
               R : constant String := Note_Of (Remote, K);
            begin
               if B /= R then
                  Changes.Append
                    (Change'(Object => To_Unbounded_String (K),
                             Base   => To_Unbounded_String (B),
                             Local  => Null_Unbounded_String,
                             Remote => To_Unbounded_String (R),
                             Local_Set => False));
               end if;
            end;
         end loop;
      end Collect_Remote_Changes;

      --  git's diff_tree_local: the local side of each remote change, left
      --  "uninitialized" when the local tree matches the base there. Result
      --  still is the local tree at this point.
      procedure Collect_Local_Changes is
      begin
         for C of Changes loop
            declare
               K : constant String := To_String (C.Object);
               L : constant String := Note_Of (Result, K);
            begin
               if L /= To_String (C.Base) then
                  C.Local := To_Unbounded_String (L);
                  C.Local_Set := True;
               end if;
            end;
         end loop;
      end Collect_Local_Changes;

      --  git's ll_merge_in_worktree: a 3-way text merge of the note, left
      --  with conflict markers labelled by the two refs.
      procedure Merge_In_Worktree (C : Change) is
         Obj : constant String := To_String (C.Object);
         Base_Text   : constant String := Note_Text (Repo, To_String (C.Base));
         Local_Text  : constant String := Note_Text (Repo, To_String (C.Local));
         Remote_Text : constant String := Note_Text (Repo, To_String (C.Remote));
      begin
         if Version.Merge.Is_Binary_Content (Base_Text)
           or else Version.Merge.Is_Binary_Content (Local_Text)
           or else Version.Merge.Is_Binary_Content (Remote_Text)
         then
            Warnings.Append
              ("Cannot merge binary files: " & Obj & " (" & Local_Ref
               & " vs. " & Remote_Ref & ")");
            Write_To_Worktree (Repo, Obj, Local_Text);
            return;
         end if;
         declare
            Opts   : Version.Merge.Merge_File_Options;
            Merged : Unbounded_String;
            Count  : Natural;
         begin
            --  git calls ll_merge with default options: the plain conflict
            --  style, Myers, and the ZEALOUS (not ZEALOUS_ALNUM) level.
            Opts.Ours_Label   := To_Unbounded_String (Local_Ref);
            Opts.Theirs_Label := To_Unbounded_String (Remote_Ref);
            Opts.Simplify_No_Alnum := False;
            Version.Merge.Merge_File
              (Local_Text, Base_Text, Remote_Text, Opts, Merged, Count);
            Write_To_Worktree (Repo, Obj, To_String (Merged));
         end;
      end Merge_In_Worktree;

      --  git's merge_one_change_manual.
      procedure Merge_Manually (C : Change) is
         Obj  : constant String := To_String (C.Object);
         Lref : constant String :=
           (if Local_Ref'Length > 0 then Local_Ref else "local version");
         Rref : constant String :=
           (if Remote_Ref'Length > 0 then Remote_Ref else "remote version");
         Removed : Boolean with Unreferenced;
      begin
         if not Has_Worktree then
            Append (Options.Commit_Msg, LF & LF & "Conflicts:" & LF);
         end if;
         Append (Options.Commit_Msg, ASCII.HT & Obj & LF);

         if Options.Verbosity >= 2 then
            Say (Output, "Auto-merging notes for " & Obj);
         end if;
         Establish_Worktree (Repo, Has_Worktree);
         if Length (C.Local) = 0 then
            if Options.Verbosity >= 1 then
               Say (Output,
                    "CONFLICT (delete/modify): Notes for object " & Obj
                    & " deleted in " & Lref & " and modified in " & Rref
                    & ". Version from " & Rref & " left in tree.");
            end if;
            Write_To_Worktree (Repo, Obj, Note_Text (Repo, To_String (C.Remote)));
         elsif Length (C.Remote) = 0 then
            if Options.Verbosity >= 1 then
               Say (Output,
                    "CONFLICT (delete/modify): Notes for object " & Obj
                    & " deleted in " & Rref & " and modified in " & Lref
                    & ". Version from " & Lref & " left in tree.");
            end if;
            Write_To_Worktree (Repo, Obj, Note_Text (Repo, To_String (C.Local)));
         else
            if Options.Verbosity >= 1 then
               Say (Output,
                    "CONFLICT ("
                    & (if Length (C.Base) = 0 then "add/add" else "content")
                    & "): Merge conflict in notes for object " & Obj);
            end if;
            Merge_In_Worktree (C);
         end if;

         Removed := Remove_Note (Result, Obj);
      end Merge_Manually;

      --  git's merge_one_change: True when the change conflicts.
      function Merge_One (C : Change) return Boolean is
         Obj : constant String := To_String (C.Object);
      begin
         case Options.Strategy is
            when Manual =>
               Merge_Manually (C);
               return True;
            when Ours =>
               if Options.Verbosity >= 2 then
                  Say (Output, "Using local notes for " & Obj);
               end if;
            when Theirs =>
               if Options.Verbosity >= 2 then
                  Say (Output, "Using remote notes for " & Obj);
               end if;
               Add_Note (Repo, Result, Obj, To_String (C.Remote),
                         Combine_Overwrite);
            when Union =>
               if Options.Verbosity >= 2 then
                  Say (Output,
                       "Concatenating local and remote notes for " & Obj);
               end if;
               Add_Note (Repo, Result, Obj, To_String (C.Remote),
                         Combine_Concatenate);
            when Cat_Sort_Uniq =>
               if Options.Verbosity >= 2 then
                  Say (Output,
                       "Concatenating unique lines in local and remote "
                       & "notes for " & Obj);
               end if;
               Add_Note (Repo, Result, Obj, To_String (C.Remote),
                         Combine_Cat_Sort_Uniq);
         end case;
         return False;
      end Merge_One;
   begin
      Conflicts := 0;
      Collect_Remote_Changes;
      Collect_Local_Changes;

      --  git's merge_changes.
      for C of Changes loop
         if C.Base = C.Remote then
            null;   --  no remote change
         elsif C.Local_Set and then C.Local = C.Remote then
            null;   --  the same change on both sides
         elsif not C.Local_Set or else C.Local = C.Base then
            --  No local change: adopt the remote one.
            Add_Note (Repo, Result, To_String (C.Object), To_String (C.Remote),
                      Combine_Overwrite);
         elsif Merge_One (C) then
            Conflicts := Conflicts + 1;
         end if;
      end loop;

      if Options.Verbosity >= 4 then
         Say (Output,
              "Merge result:" & Conflicts'Image & " unmerged notes and a "
              & (if Is_Dirty (Result) then "dirty" else "clean")
              & " notes tree");
      end if;
   end Merge_From_Diffs;

   procedure Merge
     (Repo      : Version.Repository.Repository_Handle;
      Options   : in out Merge_Options;
      Local     : in out Version.Notes.Notes_Tree;
      Result_Id : out Version.Objects.Hex_Object_Id;
      Result    : out Merge_Result;
      Output    : in out Unbounded_String;
      Warnings  : in out Version.Ref_Format.String_Vectors.Vector)
   is
      Local_Ref  : constant String := To_String (Options.Local_Ref);
      Remote_Ref : constant String := To_String (Options.Remote_Ref);
      Local_Id   : Unbounded_String;   --  "" for an unborn local ref
      Remote_Id  : Unbounded_String;   --  "" for a missing remote ref
      Base_Id    : Unbounded_String;   --  "" for no merge base
   begin
      Result_Id := Zero_Object_Id;
      Result    := Trivial;

      --  Dereference the local ref; a missing but well-formed ref is unborn.
      if Version.Refs.Ref_Exists (Repo, Local_Ref) then
         declare
            Raw : constant String :=
              To_String (Version.Refs.Resolve_Ref (Repo, Local_Ref));
            Id  : constant String := Commit_Of (Repo, Raw);
         begin
            if Id'Length = 0 then
               raise Notes_Error with
                 "Could not parse local commit " & Raw & " (" & Local_Ref & ")";
            end if;
            Local_Id := To_Unbounded_String (Id);
         end;
      elsif not Version.Ref_Names.Is_Valid_Check_Ref_Format (Local_Ref) then
         raise Notes_Error with
           "Failed to resolve local notes ref '" & Local_Ref & "'";
      end if;

      --  Dereference the remote ref; an unresolvable but well-formed name
      --  merges as an empty notes tree.
      begin
         declare
            Raw : constant String :=
              To_String (Version.Revisions.Resolve (Repo, Remote_Ref));
            Id  : constant String := Commit_Of (Repo, Raw);
         begin
            if Id'Length = 0 then
               raise Notes_Error with
                 "Could not parse remote commit " & Raw & " (" & Remote_Ref & ")";
            end if;
            Remote_Id := To_Unbounded_String (Id);
         end;
      exception
         when Ada.IO_Exceptions.Data_Error =>
            if not Version.Ref_Names.Is_Valid_Check_Ref_Format (Remote_Ref) then
               raise Notes_Error with
                 "Failed to resolve remote notes ref '" & Remote_Ref & "'";
            end if;
      end;

      if Length (Local_Id) = 0 and then Length (Remote_Id) = 0 then
         raise Notes_Error with
           "Cannot merge empty notes ref (" & Remote_Ref
           & ") into empty notes ref (" & Local_Ref & ")";
      end if;
      if Length (Local_Id) = 0 then
         Result_Id := To_Object_Id (To_String (Remote_Id));
         return;
      end if;
      if Length (Remote_Id) = 0 then
         Result_Id := To_Object_Id (To_String (Local_Id));
         return;
      end if;

      declare
         Bases : constant Version.History.Commit_Id_Vectors.Vector :=
           Version.History.Merge_Bases
             (Repo, To_Object_Id (To_String (Local_Id)),
              To_Object_Id (To_String (Remote_Id)));
      begin
         if Bases.Is_Empty then
            if Options.Verbosity >= 4 then
               Say (Output, "No merge base found; doing history-less merge");
            end if;
         elsif Natural (Bases.Length) = 1 then
            Base_Id := To_Unbounded_String (To_String (Bases.First_Element));
            if Options.Verbosity >= 4 then
               Say (Output,
                    "One merge base found (" & Short (To_String (Base_Id)) & ")");
            end if;
         else
            Base_Id := To_Unbounded_String (To_String (Bases.First_Element));
            if Options.Verbosity >= 3 then
               Say (Output,
                    "Multiple merge bases found. Using the first ("
                    & Short (To_String (Base_Id)) & ")");
            end if;
         end if;
      end;

      if Options.Verbosity >= 4 then
         Say (Output,
              "Merging remote commit " & Short (To_String (Remote_Id))
              & " into local commit " & Short (To_String (Local_Id))
              & " with merge-base "
              & (if Length (Base_Id) > 0 then Short (To_String (Base_Id))
                 else Short (To_String (Zero_Object_Id))));
      end if;

      if Remote_Id = Base_Id then
         if Options.Verbosity >= 2 then
            Say (Output, "Already up to date.");
         end if;
         Result_Id := To_Object_Id (To_String (Local_Id));
         return;
      end if;
      if Local_Id = Base_Id then
         if Options.Verbosity >= 2 then
            Say (Output, "Fast-forward");
         end if;
         Result_Id := To_Object_Id (To_String (Remote_Id));
         return;
      end if;

      declare
         Base, Remote : Notes_Tree;
         Conflicts    : Natural;
         Parents      : Version.Objects.Object_Id_Vectors.Vector;
      begin
         Load_Tree (Repo, To_String (Base_Id), Base);
         Load_Tree (Repo, To_String (Remote_Id), Remote);
         Merge_From_Diffs
           (Repo, Options, Base, Remote, Local, Conflicts, Output, Warnings);

         Parents.Append (To_Object_Id (To_String (Local_Id)));
         Parents.Append (To_Object_Id (To_String (Remote_Id)));
         Result_Id := Create_Notes_Commit
           (Repo, Local, Parents, To_String (Options.Commit_Msg));
         Result := (if Conflicts > 0 then Conflicted else Merged);
      end;
   end Merge;

   ---------------------------------------------------------------------------
   --  Merge state

   procedure Record_Partial_Merge
     (Repo      : Version.Repository.Repository_Handle;
      Result_Id : Version.Objects.Hex_Object_Id;
      Notes_Ref : String)
   is
      Ref_File : constant String := State_File (Repo, Merge_Ref);
   begin
      Version.Files.Write_Binary_File
        (State_File (Repo, Partial_Ref), To_String (Result_Id) & LF);
      if Version.Files.Exists (Ref_File) then
         declare
            Existing : constant String :=
              Trimmed (Version.Files.Read_Binary_File (Ref_File));
         begin
            if Existing = "ref: " & Notes_Ref then
               raise Notes_Error with
                 "a notes merge into " & Notes_Ref
                 & " is already in-progress at "
                 & Version.Repository.Root_Path (Repo);
            end if;
         end;
      end if;
      Version.Files.Write_Binary_File (Ref_File, "ref: " & Notes_Ref & LF);
   end Record_Partial_Merge;

   procedure Clear_Merge_State
     (Repo     : Version.Repository.Repository_Handle;
      Options  : Merge_Options;
      Output   : in out Unbounded_String;
      Errors   : in out Version.Ref_Format.String_Vectors.Vector)
   is
      Dir : constant String := Worktree_Dir (Repo);
   begin
      begin
         Version.Files.Delete_File_If_Exists (State_File (Repo, Partial_Ref));
      exception
         when others =>
            Errors.Append ("failed to delete ref " & Partial_Ref);
      end;
      begin
         Version.Files.Delete_File_If_Exists (State_File (Repo, Merge_Ref));
      exception
         when others =>
            Errors.Append ("failed to delete ref " & Merge_Ref);
      end;

      --  git's notes_merge_abort empties the worktree but keeps the
      --  directory (it might be the user's current directory); a missing
      --  directory is the failure it reports.
      if Options.Verbosity >= 3 then
         Say (Output, "Removing notes merge worktree at " & Dir & "/*");
      end if;
      if not Version.Files.Exists (Dir) then
         Errors.Append ("failed to remove 'git notes merge' worktree");
         return;
      end if;
      declare
         Search : Ada.Directories.Search_Type;
      begin
         Ada.Directories.Start_Search (Search, Dir, "");
         while Ada.Directories.More_Entries (Search) loop
            declare
               Item : Ada.Directories.Directory_Entry_Type;
               use Ada.Directories;
            begin
               Get_Next_Entry (Search, Item);
               if Simple_Name (Item) not in "." | ".." then
                  if Kind (Item) = Directory then
                     Version.Files.Delete_Directory_Tree_If_Exists
                       (Full_Name (Item));
                  else
                     Version.Files.Delete_File_If_Exists (Full_Name (Item));
                  end if;
               end if;
            end;
         end loop;
         Ada.Directories.End_Search (Search);
      exception
         when others =>
            Errors.Append ("failed to remove 'git notes merge' worktree");
      end;
   end Clear_Merge_State;

   procedure Merge_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Options   : Merge_Options;
      Result_Id : out Version.Objects.Hex_Object_Id;
      Output    : in out Unbounded_String)
   is
      Partial_File : constant String := State_File (Repo, Partial_Ref);
      Ref_File     : constant String := State_File (Repo, Merge_Ref);
      Dir          : constant String := Worktree_Dir (Repo);
   begin
      Result_Id := Zero_Object_Id;
      if not Version.Files.Exists (Partial_File) then
         raise Notes_Error with "failed to read ref " & Partial_Ref;
      end if;

      declare
         Partial_Text : constant String :=
           Trimmed (Version.Files.Read_Binary_File (Partial_File));
         Partial_Id   : constant String := Commit_Of (Repo, Partial_Text);
      begin
         if not Is_Valid_Hex_Object_Id (Partial_Text) then
            raise Notes_Error with "failed to read ref " & Partial_Ref;
         end if;
         if Partial_Id'Length = 0 then
            raise Notes_Error with
              "could not find commit from " & Partial_Ref & ".";
         end if;

         declare
            Partial : constant Version.Objects.Git_Object :=
              Version.Objects.Read_Object (Repo, To_Object_Id (Partial_Id));
            Parents : constant Version.Objects.Object_Id_Vectors.Vector :=
              Version.Objects.Commit_Parent_Ids (Partial);
            Message : constant String :=
              Version.Objects.Commit_Message (Partial);
            Tree    : Notes_Tree;
            Local_Ref : Unbounded_String;
         begin
            if not Version.Files.Exists (Ref_File) then
               raise Notes_Error with "failed to resolve " & Merge_Ref;
            end if;
            declare
               Text : constant String :=
                 Trimmed (Version.Files.Read_Binary_File (Ref_File));
            begin
               if Text'Length <= 5 or else Text (Text'First .. Text'First + 4) /= "ref: " then
                  raise Notes_Error with "failed to resolve " & Merge_Ref;
               end if;
               Local_Ref := To_Unbounded_String
                 (Trimmed (Text (Text'First + 5 .. Text'Last)));
            end;

            --  git's notes_merge_commit: every resolved note left in the
            --  worktree replaces (or adds) the partial tree's entry.
            Load_From_Commit
              (Repo, To_Object_Id (Partial_Id), To_String (Local_Ref), Tree);
            if Options.Verbosity >= 3 then
               Say (Output, "Committing notes in notes merge worktree at " & Dir);
            end if;
            if Message'Length = 0 then
               raise Notes_Error with "partial notes commit has empty message";
            end if;
            if not Version.Files.Exists (Dir) then
               raise Notes_Error with
                 "could not open " & Dir & ": No such file or directory";
            end if;

            declare
               package Name_Sets is
                 new Ada.Containers.Indefinite_Ordered_Sets (String);
               Names  : Name_Sets.Set;
               Search : Ada.Directories.Search_Type;
            begin
               Ada.Directories.Start_Search (Search, Dir, "");
               while Ada.Directories.More_Entries (Search) loop
                  declare
                     Item : Ada.Directories.Directory_Entry_Type;
                  begin
                     Ada.Directories.Get_Next_Entry (Search, Item);
                     if Ada.Directories.Simple_Name (Item) not in "." | ".."
                     then
                        Names.Include (Ada.Directories.Simple_Name (Item));
                     end if;
                  end;
               end loop;
               Ada.Directories.End_Search (Search);

               for Name of Names loop
                  if not Is_Valid_Hex_Object_Id (Name)
                    or else Name'Length /= Version.Hash.Hex_Length
                                             (Version.Repository.Algorithm (Repo))
                  then
                     if Options.Verbosity >= 3 then
                        Say (Output,
                             "Skipping non-SHA1 entry '" & Dir & "/" & Name & "'");
                     end if;
                  else
                     declare
                        Blob : constant String :=
                          To_String
                            (Version.Write.Write_Blob
                               (Repo,
                                Version.Files.Read_Binary_File
                                  (Version.Files.Join (Dir, Name))));
                     begin
                        Add_Note (Repo, Tree, Name, Blob, Combine_Overwrite);
                        if Options.Verbosity >= 4 then
                           Say (Output,
                                "Added resolved note for object " & Name & ": "
                                & Blob);
                        end if;
                     end;
                  end if;
               end loop;
            end;

            Result_Id := Create_Notes_Commit (Repo, Tree, Parents, Message);
            if Options.Verbosity >= 4 then
               Say (Output,
                    "Finalized notes merge commit: " & To_String (Result_Id));
            end if;

            --  Advance the merged-into ref from the partial commit's first
            --  parent, logging the merge's subject.
            declare
               Old : constant String :=
                 (if Parents.Is_Empty then ""
                  else To_String (Parents.First_Element));
               Ref : constant String := To_String (Local_Ref);
               Tx  : Version.Ref_Transaction.Transaction;
               Subject : Unbounded_String;
            begin
               for Ch of Message loop
                  exit when Ch = LF
                    and then Length (Subject) > 0
                    and then Element (Subject, Length (Subject)) = ' ';
                  if Ch = LF then
                     Append (Subject, ' ');
                  else
                     Append (Subject, Ch);
                  end if;
               end loop;
               --  git's update_ref dies when the ref moved meanwhile.
               if Version.Refs.Ref_Exists (Repo, Ref)
                 and then To_String (Version.Refs.Resolve_Ref (Repo, Ref)) /= Old
               then
                  raise Notes_Error with
                    "update_ref failed for ref '" & Ref & "': cannot lock ref '"
                    & Ref & "': is at "
                    & To_String (Version.Refs.Resolve_Ref (Repo, Ref))
                    & " but expected " & Old;
               end if;
               Version.Ref_Transaction.Start (Tx, Repo);
               Version.Ref_Transaction.Add_Update
                 (Tx, Ref, Result_Id, Old);
               Version.Ref_Transaction.Commit (Tx);
               Version.Reflog.Append
                 (Repo, Ref,
                  (if Old'Length > 0 then Old
                   else To_String (Zero_Object_Id)),
                  To_String (Result_Id),
                  "notes: "
                  & Ada.Strings.Fixed.Trim (To_String (Subject), Ada.Strings.Both));
            end;
         end;
      end;
   end Merge_Commit;

end Version.Notes_Merge;
