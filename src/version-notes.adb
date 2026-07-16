with Ada.Strings.Unbounded;

with Version.Ref_Transaction;
with Version.Refs;
with Version.Staging;
with Version.Tree_Cache;
with Version.Write;

package body Version.Notes is
   use Version.Objects;

   use Ada.Strings.Unbounded;

   Notes_Ref : constant String := "refs/notes/commits";

   function Notes_Tree_Entries
     (Repo : Version.Repository.Repository_Handle)
      return Version.Staging.Index_Entry_Vectors.Vector
   is
      Result : Version.Staging.Index_Entry_Vectors.Vector;
   begin
      if Version.Refs.Ref_Exists (Repo, Notes_Ref) then
         declare
            Notes_Commit : constant Version.Objects.Hex_Object_Id :=
              Version.Refs.Resolve_Ref (Repo, Notes_Ref);
            Obj   : constant Version.Objects.Git_Object :=
              Version.Objects.Read_Object (Repo, Notes_Commit);
            Cache : Version.Tree_Cache.Tree_Cache;
            Flat  : constant Version.Objects.Tree_Entry_Vectors.Vector :=
              Version.Tree_Cache.Flatten_Tree
                (Repo, Cache, Version.Objects.Commit_Tree_Id (Obj));
         begin
            for E of Flat loop
               if E.Kind /= Version.Objects.Tree_Directory then
                  Result.Append
                    (Version.Staging.Index_Entry'
                       (Path  => E.Path,
                        Id    => E.Id,
                        Mode  => E.Mode,
                        Stage => 0, Skip_Worktree => False));
               end if;
            end loop;
         end;
      end if;
      return Result;
   end Notes_Tree_Entries;

   procedure Add
     (Repo    : Version.Repository.Repository_Handle;
      Commit  : Version.Objects.Hex_Object_Id;
      Message : String)
   is
      --  git normalises a note message: trailing blank lines / whitespace are
      --  stripped and exactly one trailing newline is ensured (internal blank
      --  lines are kept), so the note blob ends in a single "\n" and matches
      --  git's note object byte-for-byte.
      function Cleanup (Text : String) return String is
         Last : Natural := Text'Last;
      begin
         while Last >= Text'First
           and then (Text (Last) = ' ' or else Text (Last) = ASCII.HT
                     or else Text (Last) = ASCII.LF
                     or else Text (Last) = ASCII.CR)
         loop
            Last := Last - 1;
         end loop;
         if Last < Text'First then
            return "";
         end if;
         return Text (Text'First .. Last) & ASCII.LF;
      end Cleanup;

      Entries : Version.Staging.Index_Entry_Vectors.Vector :=
        Notes_Tree_Entries (Repo);
      Blob    : constant Version.Objects.Hex_Object_Id :=
        Version.Write.Write_Blob (Repo, Cleanup (Message));
      Parents : Version.Objects.Object_Id_Vectors.Vector;
      Old     : Unbounded_String;
   begin
      Version.Staging.Replace_Entry
        (Entries,
         (Path  => To_Unbounded_String (To_String (Commit)),
          Id    => Blob,
          Mode  => To_Unbounded_String ("100644"),
          Stage => 0, Skip_Worktree => False));
      Version.Staging.Sort_By_Path (Entries);

      if Version.Refs.Ref_Exists (Repo, Notes_Ref) then
         Old := To_Unbounded_String
           (To_String (Version.Refs.Resolve_Ref (Repo, Notes_Ref)));
         Parents.Append (Version.Refs.Resolve_Ref (Repo, Notes_Ref));
      end if;

      declare
         Tree : constant Version.Objects.Hex_Object_Id :=
           Version.Write.Write_Tree_From_Index (Repo, Entries);
         New_Commit : constant Version.Objects.Hex_Object_Id :=
           Version.Write.Write_Commit_With_Parents
             (Repo, Tree, Parents, "Notes added by 'version notes add'");
         Tx : Version.Ref_Transaction.Transaction;
      begin
         Version.Ref_Transaction.Start (Tx, Repo);
         Version.Ref_Transaction.Add_Update
           (Tx, Notes_Ref, New_Commit, To_String (Old));
         Version.Ref_Transaction.Commit (Tx);
      end;
   end Add;

   function Show
     (Repo   : Version.Repository.Repository_Handle;
      Commit : Version.Objects.Hex_Object_Id)
      return String
   is
   begin
      if not Version.Refs.Ref_Exists (Repo, Notes_Ref) then
         return "";
      end if;

      declare
         Notes_Commit : constant Version.Objects.Hex_Object_Id :=
           Version.Refs.Resolve_Ref (Repo, Notes_Ref);
         Obj    : constant Version.Objects.Git_Object :=
           Version.Objects.Read_Object (Repo, Notes_Commit);
         Cache  : Version.Tree_Cache.Tree_Cache;
         Flat   : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Version.Tree_Cache.Flatten_Tree
             (Repo, Cache, Version.Objects.Commit_Tree_Id (Obj));
         Target : constant String := To_String (Commit);
      begin
         for E of Flat loop
            if E.Kind /= Version.Objects.Tree_Directory
              and then To_String (E.Path) = Target
            then
               return Version.Objects.Content
                        (Version.Objects.Read_Object (Repo, E.Id));
            end if;
         end loop;
         return "";
      end;
   end Show;

end Version.Notes;
