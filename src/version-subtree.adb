with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Containers.Indefinite_Hashed_Sets;
with Ada.Containers.Indefinite_Vectors;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Hash;
with Ada.Strings.Unbounded;

with Version.Branch;
with Version.Fetch;
with Version.History;
with Version.Push;
with Version.Ref_Transaction;
with Version.Reflog;
with Version.Refs;
with Version.Remotes;
with Version.Reset;
with Version.Revisions;
with Version.Staging;
with Version.Status;
with Version.Write;

package body Version.Subtree is

   use Ada.Strings.Unbounded;
   use type Version.Objects.Tree_Entry_Kind;

   package Id_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type        => String,
      Element_Type    => String,
      Hash            => Ada.Strings.Hash,
      Equivalent_Keys => "=");

   package Id_Sets is new Ada.Containers.Indefinite_Hashed_Sets
     (Element_Type        => String,
      Hash                => Ada.Strings.Hash,
      Equivalent_Elements => "=");

   package Id_Lists is new Ada.Containers.Indefinite_Vectors
     (Index_Type   => Positive,
      Element_Type => String);

   package Count_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type        => String,
      Element_Type    => Natural,
      Hash            => Ada.Strings.Hash,
      Equivalent_Keys => "=");

   package List_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type        => String,
      Element_Type    => Id_Lists.Vector,
      Hash            => Ada.Strings.Hash,
      Equivalent_Keys => "=",
      "="             => Id_Lists."=");

   --  The remote `subtree add <path-or-url> <ref>` fetches through when the
   --  repository it names is not already configured.  Registered for the
   --  duration of the fetch and removed again afterwards, so the only trace
   --  left behind is the objects -- exactly what `git fetch <url> <ref>` does.
   Scratch_Remote : constant String := "subtree-fetch-tmp";

   function Prefix_Exists_Diagnostic (Prefix : String) return String is
     ("prefix '" & Prefix & "' already exists.");

   function Prefix_Missing_Diagnostic (Prefix : String) return String is
     ("'" & Prefix & "' does not exist; use 'version subtree add'");

   function Working_Tree_Dirty_Diagnostic return String is
     ("working tree has modifications.  Cannot add.");

   function Index_Dirty_Diagnostic return String is
     ("index has modifications.  Cannot add.");

   function No_New_Revisions_Diagnostic return String is
     ("no new revisions were found");

   function Hex (Id : Version.Objects.Hex_Object_Id) return String
     renames Version.Objects.To_String;

   function Id (Text : String) return Version.Objects.Hex_Object_Id
     renames Version.Objects.To_Object_Id;

   --  Write_Commit_* terminates the message with a newline itself, so a
   --  message that already ends in one must shed it or the body doubles up.
   function Chomp (Text : String) return String is
     (if Text'Length > 0 and then Text (Text'Last) = ASCII.LF
      then Text (Text'First .. Text'Last - 1) else Text);

   --  The value of a `key: value` trailer line in a commit message, or "".
   function Trailer_Of (Text : String; Key : String) return String;

   procedure Ensure_Clean;

   function Commit_Fields
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Author    : out Unbounded_String;
      Committer : out Unbounded_String)
      return String;

   function Fetch_Source
     (Repo       : Version.Repository.Repository_Handle;
      Repository : String;
      Ref        : String)
      return Version.Objects.Hex_Object_Id;

   --  A path or URL is not a remote name -- and asking whether it is one is
   --  an error, not a False.
   function Known_Remote (Name : String) return Boolean;

   ------------------
   -- Known_Remote --
   ------------------

   function Known_Remote (Name : String) return Boolean is
   begin
      return Version.Remotes.Remote_Exists (Name);
   exception
      when others =>
         return False;
   end Known_Remote;

   ----------------
   -- Trailer_Of --
   ----------------

   function Trailer_Of (Text : String; Key : String) return String is
      Start : constant Natural := Ada.Strings.Fixed.Index (Text, Key);
      Stop  : Natural;
   begin
      if Start = 0 then
         return "";
      end if;

      Stop := Ada.Strings.Fixed.Index (Text, "" & ASCII.LF, Start + Key'Length);

      if Stop = 0 then
         Stop := Text'Last + 1;
      end if;

      return Ada.Strings.Fixed.Trim
               (Text (Start + Key'Length .. Stop - 1), Ada.Strings.Both);
   end Trailer_Of;

   ------------------
   -- Ensure_Clean --
   ------------------

   procedure Ensure_Clean is
      Result : constant Version.Status.Status_Result :=
        Version.Status.Current_Status;
   begin
      if not Result.Changes.Is_Empty or else not Result.Conflicted.Is_Empty
      then
         raise Ada.IO_Exceptions.Use_Error
           with Working_Tree_Dirty_Diagnostic;
      end if;

      if not Result.Staged.Is_Empty then
         raise Ada.IO_Exceptions.Use_Error with Index_Dirty_Diagnostic;
      end if;
   end Ensure_Clean;

   ----------------------
   -- Subtree_Tree_Id --
   ----------------------

   function Subtree_Tree_Id
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Prefix    : String)
      return String
   is
      Current : Version.Objects.Hex_Object_Id :=
        Version.Objects.Commit_Tree_Id
          (Version.Objects.Read_Object (Repo, Commit_Id));
      First   : Positive := Prefix'First;
   begin
      while First <= Prefix'Last loop
         declare
            Slash : constant Natural :=
              Ada.Strings.Fixed.Index (Prefix (First .. Prefix'Last), "/");
            Last  : constant Natural :=
              (if Slash = 0 then Prefix'Last else Slash - 1);
            Name  : constant String := Prefix (First .. Last);
            Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
              Version.Objects.Tree_Entries (Repo, Current);
            Found : Boolean := False;
         begin
            for E of Items loop
               if To_String (E.Path) = Name then
                  if E.Kind /= Version.Objects.Tree_Directory then
                     return "";
                  end if;

                  Current := E.Id;
                  Found := True;
                  exit;
               end if;
            end loop;

            if not Found then
               return "";
            end if;

            First := Last + 2;
         end;
      end loop;

      return Hex (Current);
   end Subtree_Tree_Id;

   -------------------
   -- Commit_Fields --
   -------------------

   --  Split a commit object into its verbatim author and committer lines and
   --  its message, so a copy preserves both identities and timestamps.
   function Commit_Fields
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Author    : out Unbounded_String;
      Committer : out Unbounded_String)
      return String
   is
      Data : constant String :=
        Version.Objects.Content
          (Version.Objects.Read_Object (Repo, Commit_Id));
      Pos  : Positive := Data'First;
   begin
      Author := Null_Unbounded_String;
      Committer := Null_Unbounded_String;

      while Pos <= Data'Last loop
         declare
            Stop : Natural := Ada.Strings.Fixed.Index (Data, "" & ASCII.LF,
                                                       Pos);
            Line : constant String :=
              Data (Pos .. (if Stop = 0 then Data'Last else Stop - 1));
         begin
            if Stop = 0 then
               Stop := Data'Last;
            end if;

            if Line'Length = 0 then
               --  The blank line ends the header; the rest is the message.
               return Data (Stop + 1 .. Data'Last);
            elsif Line'Length > 7
              and then Line (Line'First .. Line'First + 6) = "author "
            then
               Author :=
                 To_Unbounded_String (Line (Line'First + 7 .. Line'Last));
            elsif Line'Length > 10
              and then Line (Line'First .. Line'First + 9) = "committer "
            then
               Committer :=
                 To_Unbounded_String (Line (Line'First + 10 .. Line'Last));
            end if;

            Pos := Stop + 1;
         end;
      end loop;

      return "";
   end Commit_Fields;

   ------------------
   -- Fetch_Source --
   ------------------

   function Fetch_Source
     (Repo       : Version.Repository.Repository_Handle;
      Repository : String;
      Ref        : String)
      return Version.Objects.Hex_Object_Id
   is
      function Resolve_In (Remote_Name : String)
        return Version.Objects.Hex_Object_Id
      is
         Tracking : constant String := "refs/remotes/" & Remote_Name & "/"
           & Ref;
      begin
         if Version.Refs.Ref_Exists (Repo, Tracking) then
            return Version.Revisions.Resolve_Commit (Repo, Tracking);
         end if;

         return Version.Revisions.Resolve_Commit (Repo, Ref);
      end Resolve_In;

   begin
      if Known_Remote (Repository) then
         Version.Fetch.Fetch (Repository);
         return Resolve_In (Repository);
      end if;

      if Known_Remote (Scratch_Remote) then
         Version.Remotes.Delete_Remote (Scratch_Remote);
      end if;

      Version.Remotes.Add_Remote (Scratch_Remote, Repository);

      declare
         Result : Version.Objects.Hex_Object_Id;
      begin
         Version.Fetch.Fetch (Scratch_Remote);
         Result := Resolve_In (Scratch_Remote);
         Version.Remotes.Delete_Remote (Scratch_Remote);
         return Result;
      exception
         when others =>
            if Known_Remote (Scratch_Remote) then
               Version.Remotes.Delete_Remote (Scratch_Remote);
            end if;

            raise;
      end;
   end Fetch_Source;

   ---------
   -- Add --
   ---------

   procedure Add
     (Prefix     : String;
      Repository : String;
      Ref        : String;
      Squash     : Boolean := False;
      Message    : String := "")
   is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
   begin
      Ensure_Clean;

      declare
         Head_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Revisions.Resolve_Commit (Repo, "HEAD");
      begin
         if Subtree_Tree_Id (Repo, Head_Id, Prefix) /= "" then
            raise Ada.IO_Exceptions.Use_Error
              with Prefix_Exists_Diagnostic (Prefix);
         end if;

         declare
            Source : constant Version.Objects.Hex_Object_Id :=
              (if Repository = ""
               then Version.Revisions.Resolve_Commit (Repo, Ref)
               else Fetch_Source (Repo, Repository, Ref));

            Sub_Tree : constant Version.Objects.Hex_Object_Id :=
              Version.Objects.Commit_Tree_Id
                (Version.Objects.Read_Object (Repo, Source));

            Merged  : Version.Objects.Hex_Object_Id := Source;
            Entries : Version.Staging.Index_Entry_Vectors.Vector :=
              Version.Staging.Load (Repo);
            Parents : Version.Objects.Object_Id_Vectors.Vector;
         begin
            --  `--squash` grafts a single synthetic commit carrying the
            --  subtree's content, not the foreign history itself.
            if Squash then
               Merged :=
                 Version.Write.Write_Commit_With_Parents
                   (Repo, Sub_Tree,
                    Version.Objects.Object_Id_Vectors.Empty_Vector,
                    "Squashed '" & Prefix & "/' content from commit "
                    & Hex (Source)
                      (Hex (Source)'First .. Hex (Source)'First + 6)
                    & ASCII.LF & ASCII.LF
                    & "git-subtree-dir: " & Prefix & ASCII.LF
                    & "git-subtree-split: " & Hex (Source));
            end if;

            --  read-tree --prefix=<dir>: the foreign tree, grafted in.
            for E of Version.Objects.Flatten_Tree (Repo, Sub_Tree) loop
               Entries.Append
                 (Version.Staging.Index_Entry'
                    (Path  => To_Unbounded_String
                                (Prefix & "/" & To_String (E.Path)),
                     Id    => E.Id,
                     Mode  => E.Mode,
                     Stage => 0,
                     Skip_Worktree => False));
            end loop;

            Parents.Append (Head_Id);
            Parents.Append (Merged);

            declare
               New_Tree : constant Version.Objects.Hex_Object_Id :=
                 Version.Write.Write_Tree_From_Index (Repo, Entries);

               Body_Text : constant String :=
                 (if Message /= "" then Message
                  elsif Squash
                  then "Merge commit '" & Hex (Merged) & "' as '" & Prefix
                       & "'"
                  else "Add '" & Prefix & "/' from commit '" & Hex (Source)
                       & "'" & ASCII.LF & ASCII.LF
                       & "git-subtree-dir: " & Prefix & ASCII.LF
                       & "git-subtree-mainline: " & Hex (Head_Id) & ASCII.LF
                       & "git-subtree-split: " & Hex (Source));

               New_Commit : constant Version.Objects.Hex_Object_Id :=
                 Version.Write.Write_Commit_With_Parents
                   (Repo, New_Tree, Parents, Body_Text);
            begin
               Version.Reset.Reset_To_Commit
                 (Repo, Version.Reset.Hard, Hex (New_Commit));
            end;
         end;
      end;
   end Add;

   --  git abbreviates these to `git rev-parse --short`'s width.
   function Short
     (Repo : Version.Repository.Repository_Handle;
      Item : Version.Objects.Hex_Object_Id)
      return String
   is
      Full : constant String := Hex (Item);
      Len  : constant Positive :=
        Version.Revisions.Unique_Abbrev_Length (Repo, Item, 7);
   begin
      return Full (Full'First .. Full'First + Len - 1);
   end Short;

   --  The `<abbrev> <subject>` lines git lists in a squash commit's body:
   --  every commit reachable from To but not from From, newest first.
   function Squash_Log
     (Repo   : Version.Repository.Repository_Handle;
      From   : Version.Objects.Hex_Object_Id;
      To     : Version.Objects.Hex_Object_Id;
      Marker : String)
      return String
   is
      Seen  : Id_Sets.Set;
      Walk  : Id_Lists.Vector;
      Text  : Unbounded_String;
   begin
      --  Everything reachable from From is off the list.
      Walk.Append (Hex (From));

      while not Walk.Is_Empty loop
         declare
            C : constant String := Walk.Last_Element;
         begin
            Walk.Delete_Last;

            if not Seen.Contains (C) then
               Seen.Include (C);

               for P of Version.History.Parent_Commits (Repo, Id (C)) loop
                  Walk.Append (Hex (P));
               end loop;
            end if;
         end;
      end loop;

      --  What is left, in git's log order (first parent first, newest first).
      declare
         Queue   : Id_Lists.Vector;
         Emitted : Id_Sets.Set;
      begin
         Queue.Append (Hex (To));

         while not Queue.Is_Empty loop
            declare
               C : constant String := Queue.First_Element;
            begin
               Queue.Delete_First;

               if not Seen.Contains (C) and then not Emitted.Contains (C) then
                  Emitted.Include (C);

                  Append
                    (Text,
                     Marker & Short (Repo, Id (C)) & " "
                     & Version.Objects.Commit_Message_First_Line
                         (Version.Objects.Read_Object (Repo, Id (C)))
                     & ASCII.LF);

                  for P of Version.History.Parent_Commits (Repo, Id (C)) loop
                     Queue.Append (Hex (P));
                  end loop;
               end if;
            end;
         end loop;
      end;

      return To_String (Text);
   end Squash_Log;

   --  The most recent squash commit under Head: the one whose trailers say it
   --  stands in for a state of Prefix (a `git-subtree-split:` with no
   --  `git-subtree-mainline:`).  Both its own id and the subtree commit it
   --  names come back.
   procedure Latest_Squash
     (Repo    : Version.Repository.Repository_Handle;
      Head_Id : Version.Objects.Hex_Object_Id;
      Prefix  : String;
      Squash  : out Unbounded_String;
      Sub     : out Unbounded_String)
   is
      Walk : Id_Lists.Vector;
      Seen : Id_Sets.Set;
   begin
      Squash := Null_Unbounded_String;
      Sub := Null_Unbounded_String;

      Walk.Append (Hex (Head_Id));
      Seen.Include (Hex (Head_Id));

      while not Walk.Is_Empty loop
         declare
            C : constant String := Walk.First_Element;
            Author, Committer : Unbounded_String;
            Text : constant String := Commit_Fields (Repo, Id (C),
                                                     Author, Committer);
            Dir  : constant String := Trailer_Of (Text, "git-subtree-dir: ");
            Spl  : constant String := Trailer_Of (Text, "git-subtree-split: ");
            Main : constant String :=
              Trailer_Of (Text, "git-subtree-mainline: ");
         begin
            Walk.Delete_First;

            if Dir = Prefix and then Spl /= "" and then Main = "" then
               Squash := To_Unbounded_String (C);
               Sub := To_Unbounded_String (Spl);
               return;
            end if;

            for P of Version.History.Parent_Commits (Repo, Id (C)) loop
               if not Seen.Contains (Hex (P)) then
                  Seen.Include (Hex (P));
                  Walk.Append (Hex (P));
               end if;
            end loop;
         end;
      end loop;
   end Latest_Squash;

   ------------------
   -- Merge_Target --
   ------------------

   function Merge_Target
     (Prefix          : String;
      Repository      : String;
      Ref             : String;
      Squash          : Boolean;
      Already_Current : out Boolean)
      return Version.Objects.Hex_Object_Id
   is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;

      Source : constant Version.Objects.Hex_Object_Id :=
        (if Repository = ""
         then Version.Revisions.Resolve_Commit (Repo, Ref)
         else Fetch_Source (Repo, Repository, Ref));

      Head_Id : constant Version.Objects.Hex_Object_Id :=
        Version.Revisions.Resolve_Commit (Repo, "HEAD");
   begin
      Already_Current := False;
      Ensure_Clean;

      if Subtree_Tree_Id (Repo, Head_Id, Prefix) = "" then
         raise Ada.IO_Exceptions.Use_Error
           with Prefix_Missing_Diagnostic (Prefix);
      end if;

      if not Squash then
         return Source;
      end if;

      --  `--squash` replaces the foreign tip with a synthetic commit whose
      --  tree is that tip's, parented on the previous squash, so the subtree's
      --  own history stays out of ours.
      declare
         Sub_Tree : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.Commit_Tree_Id
             (Version.Objects.Read_Object (Repo, Source));
         Parents  : Version.Objects.Object_Id_Vectors.Vector;
         Old_Sq   : Unbounded_String;
         Old_Sub  : Unbounded_String;
      begin
         Latest_Squash (Repo, Head_Id, Prefix, Old_Sq, Old_Sub);

         if Old_Sq = "" then
            raise Ada.IO_Exceptions.Use_Error
              with "can't squash-merge: '" & Prefix & "' was never added.";
         end if;

         if Old_Sub = Hex (Source) then
            Already_Current := True;
            return Source;
         end if;

         Parents.Append (Id (To_String (Old_Sq)));

         return Version.Write.Write_Commit_With_Parents
           (Repo, Sub_Tree, Parents,
            "Squashed '" & Prefix & "/' changes from "
            & Short (Repo, Id (To_String (Old_Sub))) & ".."
            & Short (Repo, Source) & ASCII.LF & ASCII.LF
            & Squash_Log (Repo, Id (To_String (Old_Sub)), Source, "")
            & Squash_Log (Repo, Source, Id (To_String (Old_Sub)), "REVERT: ")
            & ASCII.LF
            & "git-subtree-dir: " & Prefix & ASCII.LF
            & "git-subtree-split: " & Hex (Source));
      end;
   end Merge_Target;

   -----------
   -- Merge --
   -----------

   procedure Merge
     (Prefix     : String;
      Repository : String;
      Ref        : String;
      Squash     : Boolean := False;
      Message    : String := "")
   is
      Already : Boolean;
      Target  : constant Version.Objects.Hex_Object_Id :=
        Merge_Target (Prefix, Repository, Ref, Squash, Already);
      Options : Version.Branch.Merge_Options;
   begin
      if Already then
         return;
      end if;

      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      Options.Fast_Forward_Explicit := True;
      Options.Subtree := True;
      Options.Subtree_Prefix := To_Unbounded_String (Prefix);

      if Message /= "" then
         Options.Message := To_Unbounded_String (Message);
      end if;

      Version.Branch.Merge (Hex (Target), Options);
   end Merge;

   -----------
   -- Split --
   -----------

   function Split
     (Repo    : Version.Repository.Repository_Handle;
      Prefix  : String;
      Rev     : String := "HEAD";
      Branch  : String := "";
      Onto    : String := "";
      Rejoin  : Boolean := False;
      Ignore_Joins : Boolean := False;
      Updated : out Boolean)
      return Version.Objects.Hex_Object_Id
   is
      Tip : constant Version.Objects.Hex_Object_Id :=
        Version.Revisions.Resolve_Commit (Repo, Rev);

      --  Old commit -> the commit that stands for it in the split lineage.
      Cache    : Id_Maps.Map;
      No_Tree  : Id_Sets.Set;
      Excluded : Id_Sets.Set;

      Latest_New : Unbounded_String;
      Latest_Old : Unbounded_String;

      procedure Seed_From_Prior_Splits;

      function Top_Tree (Commit_Id : String) return String is
        (Hex (Version.Objects.Commit_Tree_Id
                (Version.Objects.Read_Object (Repo, Id (Commit_Id)))));

      procedure Exclude_History (From : String);

      function Copy_Or_Skip
        (Old_Rev : String;
         Tree    : String;
         Parents : Id_Lists.Vector)
         return String;

      ---------------------
      -- Exclude_History --
      ---------------------

      procedure Exclude_History (From : String) is
         Walk : Id_Lists.Vector;
      begin
         Walk.Append (From);

         while not Walk.Is_Empty loop
            declare
               C : constant String := Walk.Last_Element;
            begin
               Walk.Delete_Last;

               if not Excluded.Contains (C) then
                  Excluded.Include (C);

                  for P of Version.History.Parent_Commits (Repo, Id (C)) loop
                     Walk.Append (Hex (P));
                  end loop;
               end if;
            end;
         end loop;
      end Exclude_History;

      --------------------------
      -- Seed_From_Prior_Splits --
      --------------------------

      --  `add`, `merge --squash` and `split --rejoin` leave `git-subtree-*`
      --  trailers behind.  They tell us which of our commits already have a
      --  counterpart in the split lineage, so a re-split neither re-copies
      --  that history nor invents new ids for it.
      procedure Seed_From_Prior_Splits is
         Walk : Id_Lists.Vector;
         Seen : Id_Sets.Set;
      begin
         Walk.Append (Hex (Tip));
         Seen.Include (Hex (Tip));

         while not Walk.Is_Empty loop
            declare
               C : constant String := Walk.First_Element;
               Author, Committer : Unbounded_String;
               Text : constant String :=
                 Commit_Fields (Repo, Id (C), Author, Committer);

               function Trailer (Key : String) return String is
                  Start : constant Natural :=
                    Ada.Strings.Fixed.Index (Text, Key);
                  Stop  : Natural;
               begin
                  if Start = 0 then
                     return "";
                  end if;

                  Stop := Ada.Strings.Fixed.Index
                    (Text, "" & ASCII.LF, Start + Key'Length);

                  if Stop = 0 then
                     Stop := Text'Last + 1;
                  end if;

                  return Ada.Strings.Fixed.Trim
                    (Text (Start + Key'Length .. Stop - 1),
                     Ada.Strings.Both);
               end Trailer;

               Dir : constant String := Trailer ("git-subtree-dir: ");

               Add_Subject : constant String :=
                 "Add '" & Prefix & "/' from commit '";

               --  `--ignore-joins` does not ignore the original `add`: it only
               --  stops honouring the joins a later `merge`/`--rejoin` left,
               --  so git looks for the add commit by subject instead of by
               --  trailer.  Either way the trailers on the commit it finds are
               --  what seeds the cache.
               Relevant : constant Boolean :=
                 (if Ignore_Joins
                  then Text'Length >= Add_Subject'Length
                       and then Text (Text'First
                                      .. Text'First + Add_Subject'Length - 1)
                            = Add_Subject
                  else Dir = Prefix or else Dir = Prefix & "/");
            begin
               Walk.Delete_First;

               if Relevant then
                  declare
                     Main : constant String :=
                       Trailer ("git-subtree-mainline: ");
                     Sub  : constant String :=
                       Trailer ("git-subtree-split: ");
                  begin
                     if Sub /= "" and then Main = "" then
                        --  A squash commit: it stands in for the subtree
                        --  commit its trailer names.
                        if not Cache.Contains (C) then
                           Cache.Insert (C, Sub);
                        end if;
                     elsif Sub /= "" and then Main /= "" then
                        if not Cache.Contains (Main) then
                           Cache.Insert (Main, Sub);
                        end if;

                        if not Cache.Contains (Sub) then
                           Cache.Insert (Sub, Sub);
                        end if;

                        Exclude_History (Main);
                        Exclude_History (Sub);
                     end if;
                  end;
               end if;

               for P of Version.History.Parent_Commits (Repo, Id (C)) loop
                  if not Seen.Contains (Hex (P)) then
                     Seen.Include (Hex (P));
                     Walk.Append (Hex (P));
                  end if;
               end loop;
            end;
         end loop;

         --  git excludes the *parents* of the previously-split commits
         --  (`^main^ ^sub^`), not the commits themselves.
         for Cur in Cache.Iterate loop
            Excluded.Exclude (Id_Maps.Key (Cur));
         end loop;
      end Seed_From_Prior_Splits;

      ------------------
      -- Copy_Or_Skip --
      ------------------

      --  If one of the new parents already carries exactly this tree, that
      --  parent *is* this commit's split counterpart -- unless a second,
      --  divergent parent brings history that would be lost by skipping.
      function Copy_Or_Skip
        (Old_Rev : String;
         Tree    : String;
         Parents : Id_Lists.Vector)
         return String
      is
         Identical    : Unbounded_String;
         Nonidentical : Unbounded_String;
         Copy         : Boolean := False;
         Unique       : Id_Lists.Vector;
         Ids          : Version.Objects.Object_Id_Vectors.Vector;
      begin
         for P of Parents loop
            declare
               PT : constant String := Top_Tree (P);
            begin
               if PT = Tree then
                  if Identical /= "" then
                     declare
                        Base : constant String :=
                          Hex (Version.History.Merge_Base
                                 (Repo, Id (To_String (Identical)), Id (P)));
                     begin
                        if To_String (Identical) = Base then
                           Identical := To_Unbounded_String (P);
                        elsif P /= Base then
                           Copy := True;
                        end if;
                     end;
                  else
                     Identical := To_Unbounded_String (P);
                  end if;
               else
                  Nonidentical := To_Unbounded_String (P);
               end if;

               if not Unique.Contains (P) then
                  Unique.Append (P);
               end if;
            end;
         end loop;

         if Identical /= "" and then Nonidentical /= "" then
            --  History along the other branch would vanish if we skipped.
            if not Version.History.Is_Ancestor
                     (Repo, Id (To_String (Nonidentical)),
                      Id (To_String (Identical)))
            then
               Copy := True;
            end if;
         end if;

         if Identical /= "" and then not Copy then
            return To_String (Identical);
         end if;

         declare
            Author, Committer : Unbounded_String;
            Text : constant String :=
              Commit_Fields (Repo, Id (Old_Rev), Author, Committer);
         begin
            for P of Unique loop
               Ids.Append (Id (P));
            end loop;

            return Hex
              (Version.Write.Write_Commit_Raw
                 (Repo, Id (Tree), Ids,
                  To_String (Author), To_String (Committer), Chomp (Text)));
         end;
      end Copy_Or_Skip;

      Order : Id_Lists.Vector;
   begin
      Updated := False;

      if Subtree_Tree_Id (Repo, Tip, Prefix) = "" then
         raise Ada.IO_Exceptions.Use_Error
           with Prefix_Missing_Diagnostic (Prefix);
      end if;

      if Rejoin then
         Ensure_Clean;
      end if;

      --  `--onto`: that history is already just the subdirectory, so every
      --  commit in it stands for itself.
      if Onto /= "" then
         declare
            Walk : Id_Lists.Vector;
            Seen : Id_Sets.Set;
         begin
            Walk.Append (Hex (Version.Revisions.Resolve_Commit (Repo, Onto)));

            while not Walk.Is_Empty loop
               declare
                  C : constant String := Walk.Last_Element;
               begin
                  Walk.Delete_Last;

                  if not Seen.Contains (C) then
                     Seen.Include (C);

                     if not Cache.Contains (C) then
                        Cache.Insert (C, C);
                     end if;

                     for P of Version.History.Parent_Commits (Repo, Id (C))
                     loop
                        Walk.Append (Hex (P));
                     end loop;
                  end if;
               end;
            end loop;
         end;
      end if;

      Seed_From_Prior_Splits;

      --  Topological order, parents first, over what is left after the
      --  exclusions -- the same set `git rev-list --topo-order --reverse
      --  --parents <rev> <unrevs>` walks.
      declare
         Included  : Id_Sets.Set;
         Pending   : Id_Lists.Vector;
         Ready     : Id_Lists.Vector;
         Remaining : Count_Maps.Map;   --  commit -> unemitted parent count
         Children  : List_Maps.Map;    --  commit -> the commits parented on it
      begin
         Pending.Append (Hex (Tip));

         while not Pending.Is_Empty loop
            declare
               C : constant String := Pending.Last_Element;
            begin
               Pending.Delete_Last;

               if not Included.Contains (C)
                 and then not Excluded.Contains (C)
               then
                  Included.Include (C);

                  for P of Version.History.Parent_Commits (Repo, Id (C)) loop
                     Pending.Append (Hex (P));
                  end loop;
               end if;
            end;
         end loop;

         for C of Included loop
            declare
               N : Natural := 0;
            begin
               for P of Version.History.Parent_Commits (Repo, Id (C)) loop
                  if Included.Contains (Hex (P)) then
                     N := N + 1;

                     if not Children.Contains (Hex (P)) then
                        Children.Insert (Hex (P), Id_Lists.Empty_Vector);
                     end if;

                     declare
                        Kids : Id_Lists.Vector := Children.Element (Hex (P));
                     begin
                        Kids.Append (C);
                        Children.Replace (Hex (P), Kids);
                     end;
                  end if;
               end loop;

               Remaining.Insert (C, N);

               if N = 0 then
                  Ready.Append (C);
               end if;
            end;
         end loop;

         while not Ready.Is_Empty loop
            declare
               C : constant String := Ready.First_Element;
            begin
               Ready.Delete_First;
               Order.Append (C);

               if Children.Contains (C) then
                  for Kid of Children.Element (C) loop
                     declare
                        Left : constant Natural := Remaining.Element (Kid) - 1;
                     begin
                        Remaining.Replace (Kid, Left);

                        if Left = 0 then
                           Ready.Append (Kid);
                        end if;
                     end;
                  end loop;
               end if;
            end;
         end loop;
      end;

      for C of Order loop
         if not Cache.Contains (C) then
            declare
               Tree    : constant String := Subtree_Tree_Id (Repo, Id (C), Prefix);
               Mapped  : Id_Lists.Vector;
            begin
               for P of Version.History.Parent_Commits (Repo, Id (C)) loop
                  if Cache.Contains (Hex (P)) then
                     Mapped.Append (Cache.Element (Hex (P)));
                  end if;
               end loop;

               if Tree = "" then
                  No_Tree.Include (C);

                  if not Mapped.Is_Empty then
                     Cache.Insert (C, C);
                  end if;
               else
                  declare
                     New_Rev : constant String :=
                       Copy_Or_Skip (C, Tree, Mapped);
                  begin
                     Cache.Insert (C, New_Rev);
                     Latest_New := To_Unbounded_String (New_Rev);
                     Latest_Old := To_Unbounded_String (C);
                  end;
               end if;
            end;
         end if;
      end loop;

      if Latest_New = "" then
         --  Nothing new to split: the prefix's history is already out there.
         if Cache.Contains (Hex (Tip)) then
            Latest_New := To_Unbounded_String (Cache.Element (Hex (Tip)));
            Latest_Old := To_Unbounded_String (Hex (Tip));
         else
            raise Ada.IO_Exceptions.Use_Error with No_New_Revisions_Diagnostic;
         end if;
      end if;

      declare
         Result : constant Version.Objects.Hex_Object_Id :=
           Id (To_String (Latest_New));
      begin
         if Rejoin then
            declare
               Note : constant String :=
                 "Split '" & Prefix & "/' into commit '"
                 & To_String (Latest_New) & "'" & ASCII.LF & ASCII.LF
                 & "git-subtree-dir: " & Prefix & ASCII.LF
                 & "git-subtree-mainline: " & To_String (Latest_Old)
                 & ASCII.LF
                 & "git-subtree-split: " & To_String (Latest_New);
            begin
               Merge (Prefix, "", To_String (Latest_New), False, Note);
            end;
         end if;

         if Branch /= "" then
            declare
               Ref_Path : constant String := "refs/heads/" & Branch;
               Old_Id   : Unbounded_String;
               Tx       : Version.Ref_Transaction.Transaction;
            begin
               if Version.Refs.Ref_Exists (Repo, Ref_Path) then
                  declare
                     Tip_Now : constant Version.Objects.Hex_Object_Id :=
                       Version.Revisions.Resolve_Commit (Repo, Ref_Path);
                  begin
                     --  git refuses to rewind a split branch.
                     if not Version.History.Is_Ancestor
                              (Repo, Tip_Now, Result)
                     then
                        raise Ada.IO_Exceptions.Use_Error
                          with "branch '" & Branch
                               & "' is not an ancestor of commit '"
                               & To_String (Latest_New) & "'.";
                     end if;

                     Old_Id := To_Unbounded_String (Hex (Tip_Now));
                     Updated := True;
                  end;
               end if;

               Version.Ref_Transaction.Start (Tx, Repo);
               Version.Ref_Transaction.Add_Update
                 (Item         => Tx,
                  Ref_Name     => Ref_Path,
                  New_Id       => Result,
                  Expected_Old =>
                    (if Old_Id = "" then [1 .. 40 => '0']
                     else To_String (Old_Id)));
               Version.Ref_Transaction.Commit (Tx);

               Version.Reflog.Append
                 (Repo    => Repo,
                  Ref     => Ref_Path,
                  Old_Id  =>
                    (if Old_Id = "" then [1 .. 40 => '0']
                     else To_String (Old_Id)),
                  New_Id  => Hex (Result),
                  Message => "subtree split");
            end;
         end if;

         return Result;
      end;
   end Split;

   ----------
   -- Push --
   ----------

   procedure Push
     (Prefix     : String;
      Repository : String;
      Local_Rev  : String;
      Remote_Ref : String;
      Force      : Boolean := False)
   is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
      Updated : Boolean;
      Local   : constant Version.Objects.Hex_Object_Id :=
        Split (Repo, Prefix, Local_Rev, Updated => Updated);
      Scratch : Boolean := False;
   begin
      if not Known_Remote (Repository) then
         Version.Remotes.Add_Remote (Scratch_Remote, Repository);
         Scratch := True;
      end if;

      declare
         Remote_Name : constant String :=
           (if Scratch then Scratch_Remote else Repository);
      begin
         Version.Push.Push_Refspec
           (Remote_Name => Remote_Name,
            Source      => Hex (Local),
            Dest_Ref    => "refs/heads/" & Remote_Ref,
            Force       => Force);

         if Scratch then
            Version.Remotes.Delete_Remote (Scratch_Remote);
         end if;
      exception
         when others =>
            if Scratch and then Known_Remote (Scratch_Remote)
            then
               Version.Remotes.Delete_Remote (Scratch_Remote);
            end if;

            raise;
      end;
   end Push;

end Version.Subtree;
