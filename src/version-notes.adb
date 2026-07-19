with Ada.IO_Exceptions;
with Ada.Strings.Unbounded;

with Version.Ref_Transaction;
with Version.Refs;
with Version.Staging;
with Version.Tree_Cache;
with Version.Write;

package body Version.Notes is
   use Version.Objects;

   use Ada.Strings.Unbounded;

   function Qualify_Ref (Name : String) return String is
   begin
      if Name'Length = 0 then
         return Default_Ref;
      elsif Name'Length > 5
        and then Name (Name'First .. Name'First + 4) = "refs/"
      then
         return Name;
      else
         return "refs/notes/" & Name;
      end if;
   end Qualify_Ref;

   function Notes_Tree_Entries
     (Repo : Version.Repository.Repository_Handle;
      Ref  : String)
      return Version.Staging.Index_Entry_Vectors.Vector
   is
      Notes_Ref : constant String := Qualify_Ref (Ref);
      Result    : Version.Staging.Index_Entry_Vectors.Vector;
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

   --  Write Entries as the notes tree and advance the ref to a new commit.
   procedure Commit_Notes_Tree
     (Repo    : Version.Repository.Repository_Handle;
      Ref     : String;
      Entries : Version.Staging.Index_Entry_Vectors.Vector;
      Message : String)
   is
      Notes_Ref : constant String := Qualify_Ref (Ref);
      Parents   : Version.Objects.Object_Id_Vectors.Vector;
      Old       : Unbounded_String;
   begin
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
             (Repo, Tree, Parents, Message);
         Tx : Version.Ref_Transaction.Transaction;
      begin
         Version.Ref_Transaction.Start (Tx, Repo);
         Version.Ref_Transaction.Add_Update
           (Tx, Notes_Ref, New_Commit, To_String (Old));
         Version.Ref_Transaction.Commit (Tx);
      end;
   end Commit_Notes_Tree;

   procedure Add
     (Repo    : Version.Repository.Repository_Handle;
      Commit  : Version.Objects.Hex_Object_Id;
      Message : String;
      Ref     : String := Default_Ref)
   is
      Entries : Version.Staging.Index_Entry_Vectors.Vector :=
        Notes_Tree_Entries (Repo, Ref);
      Blob    : constant Version.Objects.Hex_Object_Id :=
        Version.Write.Write_Blob (Repo, Cleanup (Message));
   begin
      Version.Staging.Replace_Entry
        (Entries,
         (Path  => To_Unbounded_String (To_String (Commit)),
          Id    => Blob,
          Mode  => To_Unbounded_String ("100644"),
          Stage => 0, Skip_Worktree => False));
      Version.Staging.Sort_By_Path (Entries);

      Commit_Notes_Tree
        (Repo, Ref, Entries, "Notes added by 'git notes add'");
   end Add;

   function Show
     (Repo   : Version.Repository.Repository_Handle;
      Commit : Version.Objects.Hex_Object_Id;
      Ref    : String := Default_Ref)
      return String
   is
      Target : constant String := To_String (Commit);
   begin
      for E of Notes_Tree_Entries (Repo, Ref) loop
         if To_String (E.Path) = Target then
            return Version.Objects.Content
                     (Version.Objects.Read_Object (Repo, E.Id));
         end if;
      end loop;
      return "";
   end Show;

   function List
     (Repo : Version.Repository.Repository_Handle;
      Ref  : String := Default_Ref)
      return Note_Vectors.Vector
   is
      Result : Note_Vectors.Vector;
   begin
      for E of Notes_Tree_Entries (Repo, Ref) loop
         Result.Append
           (Note_Entry'
              (Commit    => E.Path,
               Note_Blob =>
                 To_Unbounded_String (Version.Objects.To_String (E.Id))));
      end loop;
      return Result;
   end List;

   function Has_Note
     (Repo   : Version.Repository.Repository_Handle;
      Commit : Version.Objects.Hex_Object_Id;
      Ref    : String := Default_Ref)
      return Boolean
   is
      Target : constant String := To_String (Commit);
   begin
      for E of Notes_Tree_Entries (Repo, Ref) loop
         if To_String (E.Path) = Target then
            return True;
         end if;
      end loop;
      return False;
   end Has_Note;

   procedure Remove
     (Repo   : Version.Repository.Repository_Handle;
      Commit : Version.Objects.Hex_Object_Id;
      Ref    : String := Default_Ref)
   is
      Entries : Version.Staging.Index_Entry_Vectors.Vector :=
        Notes_Tree_Entries (Repo, Ref);
      Target  : constant String := To_String (Commit);
      Kept    : Version.Staging.Index_Entry_Vectors.Vector;
      Found   : Boolean := False;
   begin
      for E of Entries loop
         if To_String (E.Path) = Target then
            Found := True;
         else
            Kept.Append (E);
         end if;
      end loop;

      if not Found then
         raise Ada.IO_Exceptions.Data_Error with
           "Object " & Target & " has no note";
      end if;

      Commit_Notes_Tree
        (Repo, Ref, Kept, "Notes removed by 'git notes remove'");
   end Remove;

   procedure Append
     (Repo    : Version.Repository.Repository_Handle;
      Commit  : Version.Objects.Hex_Object_Id;
      Message : String;
      Ref     : String := Default_Ref)
   is
      Existing : constant String := Show (Repo, Commit, Ref);
   begin
      if Existing'Length = 0 then
         Add (Repo, Commit, Message, Ref);
      else
         --  git separates an appended paragraph with a blank line.
         Add (Repo, Commit,
              Cleanup (Existing) & ASCII.LF & Message, Ref);
      end if;
   end Append;

   procedure Copy
     (Repo  : Version.Repository.Repository_Handle;
      From  : Version.Objects.Hex_Object_Id;
      To    : Version.Objects.Hex_Object_Id;
      Force : Boolean := False;
      Ref   : String := Default_Ref)
   is
      Source : constant String := Show (Repo, From, Ref);
   begin
      if Source'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with
           "missing notes on source object " & To_String (From)
           & ". Cannot copy.";
      end if;

      if not Force and then Has_Note (Repo, To, Ref) then
         raise Ada.IO_Exceptions.Data_Error with
           "Cannot copy notes. Found existing notes for object "
           & To_String (To) & ". Use '-f' to overwrite existing notes";
      end if;

      Add (Repo, To, Source, Ref);
   end Copy;

   procedure Prune
     (Repo : Version.Repository.Repository_Handle;
      Ref  : String := Default_Ref)
   is
      Entries : constant Version.Staging.Index_Entry_Vectors.Vector :=
        Notes_Tree_Entries (Repo, Ref);
      Kept    : Version.Staging.Index_Entry_Vectors.Vector;
      Dropped : Boolean := False;

      --  A note whose commit is gone is unreachable annotation; git drops it.
      function Commit_Exists (Hex : String) return Boolean is
         Ignored : constant Version.Objects.Git_Object :=
           Version.Objects.Read_Object
             (Repo, Version.Objects.To_Object_Id (Hex));
         pragma Unreferenced (Ignored);
      begin
         return True;
      exception
         when others =>
            return False;
      end Commit_Exists;
   begin
      for E of Entries loop
         if Commit_Exists (To_String (E.Path)) then
            Kept.Append (E);
         else
            Dropped := True;
         end if;
      end loop;

      if Dropped then
         Commit_Notes_Tree
           (Repo, Ref, Kept, "Notes removed by 'git notes prune'");
      end if;
   end Prune;

end Version.Notes;
