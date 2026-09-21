with Ada.Characters.Handling;
with Ada.Containers.Indefinite_Ordered_Sets;
with Ada.Environment_Variables;
with Ada.IO_Exceptions;

with Version.Config;
with Version.Hash;
with Version.Ref_Transaction;
with Version.Reflog;
with Version.Refs;
with Version.Staging;
with Version.Tree_Cache;
with Version.Write;

package body Version.Notes is
   use Version.Objects;

   use Ada.Strings.Unbounded;

   LF : constant Character := Character'Val (10);

   function Has_Prefix (Text, Prefix : String) return Boolean is
     (Text'Length >= Prefix'Length
      and then Text (Text'First .. Text'First + Prefix'Length - 1) = Prefix);

   function Qualify_Ref (Name : String) return String is
   begin
      if Name'Length = 0 then
         return Default_Ref;
      elsif Has_Prefix (Name, "refs/notes/") then
         return Name;
      elsif Has_Prefix (Name, "notes/") then
         return "refs/" & Name;
      else
         return "refs/notes/" & Name;
      end if;
   end Qualify_Ref;

   function Default_Notes_Ref
     (Repo : Version.Repository.Repository_Handle) return String is
   begin
      if Ada.Environment_Variables.Exists ("GIT_NOTES_REF")
        and then Ada.Environment_Variables.Value ("GIT_NOTES_REF")'Length > 0
      then
         return Ada.Environment_Variables.Value ("GIT_NOTES_REF");
      elsif Version.Config.Has_Key (Repo, "core.notesref") then
         return Version.Config.Get_Value (Repo, "core.notesref");
      else
         return Default_Ref;
      end if;
   end Default_Notes_Ref;

   function Parse_Combine_Mode
     (Text : String; Mode : out Combine_Mode) return Boolean
   is
      Lower : constant String := Ada.Characters.Handling.To_Lower (Text);
   begin
      if Lower = "overwrite" then
         Mode := Combine_Overwrite;
      elsif Lower = "ignore" then
         Mode := Combine_Ignore;
      elsif Lower = "concatenate" then
         Mode := Combine_Concatenate;
      elsif Lower = "cat_sort_uniq" then
         Mode := Combine_Cat_Sort_Uniq;
      else
         Mode := Combine_Overwrite;
         return False;
      end if;
      return True;
   end Parse_Combine_Mode;

   ---------------------------------------------------------------------------
   --  Loading

   --  git's path_to_oid: a note's tree path with any fanout slashes removed
   --  must be exactly one full object id; anything else in the tree is not a
   --  note and is left alone.
   function Path_To_Object
     (Repo : Version.Repository.Repository_Handle; Path : String)
      return String
   is
      Width  : constant Positive :=
        Version.Hash.Hex_Length (Version.Repository.Algorithm (Repo));
      Result : String (1 .. Path'Length);
      Last   : Natural := 0;
   begin
      for C of Path loop
         if C /= '/' then
            Last := Last + 1;
            Result (Last) := C;
         end if;
      end loop;
      if Last /= Width
        or else not Version.Objects.Is_Valid_Hex_Object_Id (Result (1 .. Last))
      then
         return "";
      end if;
      return Ada.Characters.Handling.To_Lower (Result (1 .. Last));
   end Path_To_Object;

   procedure Load_From_Commit
     (Repo   : Version.Repository.Repository_Handle;
      Commit : Version.Objects.Hex_Object_Id;
      Ref    : String;
      Tree   : out Notes_Tree)
   is
      Obj   : constant Version.Objects.Git_Object :=
        Version.Objects.Read_Object (Repo, Commit);
      Cache : Version.Tree_Cache.Tree_Cache;
      Flat  : constant Version.Objects.Tree_Entry_Vectors.Vector :=
        Version.Tree_Cache.Flatten_Tree
          (Repo, Cache, Version.Objects.Commit_Tree_Id (Obj));
   begin
      Tree := (Ref => To_Unbounded_String (Ref), others => <>);
      for E of Flat loop
         if E.Kind /= Version.Objects.Tree_Directory then
            declare
               Object : constant String :=
                 Path_To_Object (Repo, To_String (E.Path));
            begin
               if Object'Length > 0 then
                  Tree.Notes.Include (Object, To_String (E.Id));
               end if;
            end;
         end if;
      end loop;
   end Load_From_Commit;

   function Empty_Tree (Ref : String) return Notes_Tree is
     (Ref => To_Unbounded_String (Ref), others => <>);

   procedure Load
     (Repo : Version.Repository.Repository_Handle;
      Ref  : String;
      Tree : out Notes_Tree) is
   begin
      if Version.Refs.Ref_Exists (Repo, Ref) then
         Load_From_Commit
           (Repo, Version.Refs.Resolve_Ref (Repo, Ref), Ref, Tree);
      else
         Tree := (Ref => To_Unbounded_String (Ref), others => <>);
      end if;
   end Load;

   function Ref_Of (Tree : Notes_Tree) return String is (To_String (Tree.Ref));
   function Is_Dirty (Tree : Notes_Tree) return Boolean is (Tree.Dirty);

   function Note_Of (Tree : Notes_Tree; Object : String) return String is
      C : constant Note_Maps.Cursor := Tree.Notes.Find (Object);
   begin
      return (if Note_Maps.Has_Element (C) then Note_Maps.Element (C) else "");
   end Note_Of;

   ---------------------------------------------------------------------------
   --  Combining

   --  A blob's content, or "" for an empty id, a missing object or a
   --  non-blob (git's combine functions treat all three as "no note").
   function Blob_Text
     (Repo : Version.Repository.Repository_Handle; Id : String) return String is
   begin
      if Id'Length = 0 then
         return "";
      end if;
      declare
         Obj : constant Version.Objects.Git_Object :=
           Version.Objects.Read_Object (Repo, To_Object_Id (Id));
      begin
         if Version.Objects.Kind (Obj) /= Version.Objects.Blob_Object then
            return "";
         end if;
         return Version.Objects.Content (Obj);
      end;
   exception
      when Ada.IO_Exceptions.Data_Error | Ada.IO_Exceptions.Name_Error =>
         return "";
   end Blob_Text;

   --  git's combine_notes_concatenate: Cur, one newline stripped, a blank
   --  line, then New_Id's content. Either side empty yields the other.
   function Concatenate
     (Repo : Version.Repository.Repository_Handle; Cur, New_Id : String)
      return String
   is
      New_Text : constant String := Blob_Text (Repo, New_Id);
   begin
      if New_Text'Length = 0 then
         return Cur;
      end if;
      declare
         Cur_Text : constant String := Blob_Text (Repo, Cur);
         Last     : Natural := Cur_Text'Last;
      begin
         if Cur_Text'Length = 0 then
            return New_Id;
         end if;
         if Cur_Text (Last) = LF then
            Last := Last - 1;
         end if;
         return To_String
           (Version.Write.Write_Blob
              (Repo, Cur_Text (Cur_Text'First .. Last) & LF & LF & New_Text));
      end;
   end Concatenate;

   --  git's combine_notes_cat_sort_uniq: the union of both notes' non-empty
   --  lines, sorted bytewise and deduplicated, one per line.
   function Cat_Sort_Uniq
     (Repo : Version.Repository.Repository_Handle; Cur, New_Id : String)
      return String
   is
      package Line_Sets is new Ada.Containers.Indefinite_Ordered_Sets (String);
      Lines  : Line_Sets.Set;
      Result : Unbounded_String;

      procedure Add_Lines (Text : String) is
         First : Positive := Text'First;
      begin
         for K in Text'Range loop
            if Text (K) = LF then
               if K > First then
                  Lines.Include (Text (First .. K - 1));
               end if;
               First := K + 1;
            end if;
         end loop;
         if Text'Last >= First then
            Lines.Include (Text (First .. Text'Last));
         end if;
      end Add_Lines;
   begin
      Add_Lines (Blob_Text (Repo, Cur));
      Add_Lines (Blob_Text (Repo, New_Id));
      for L of Lines loop
         Append (Result, L);
         Append (Result, LF);
      end loop;
      return To_String (Version.Write.Write_Blob (Repo, To_String (Result)));
   end Cat_Sort_Uniq;

   procedure Add_Note
     (Repo    : Version.Repository.Repository_Handle;
      Tree    : in out Notes_Tree;
      Object  : String;
      Note    : String;
      Combine : Combine_Mode := Combine_Overwrite)
   is
      Existing : constant String := Note_Of (Tree, Object);
   begin
      Tree.Dirty := True;
      if Existing'Length = 0 then
         --  git's note_tree_insert: an empty ("null") note on an object
         --  without one inserts nothing.
         if Note'Length > 0 then
            Tree.Notes.Include (Object, Note);
         end if;
         return;
      end if;
      if Existing = Note then
         return;
      end if;
      declare
         Combined : constant String :=
           (case Combine is
               when Combine_Overwrite     => Note,
               when Combine_Ignore        => Existing,
               when Combine_Concatenate   => Concatenate (Repo, Existing, Note),
               when Combine_Cat_Sort_Uniq => Cat_Sort_Uniq (Repo, Existing, Note));
      begin
         if Combined'Length = 0 then
            Tree.Notes.Delete (Object);
         else
            Tree.Notes.Include (Object, Combined);
         end if;
      end;
   end Add_Note;

   function Remove_Note
     (Tree : in out Notes_Tree; Object : String) return Boolean is
   begin
      if not Tree.Notes.Contains (Object) then
         return False;
      end if;
      Tree.Notes.Delete (Object);
      Tree.Dirty := True;
      return True;
   end Remove_Note;

   function Copy_Note
     (Repo    : Version.Repository.Repository_Handle;
      Tree    : in out Notes_Tree;
      From    : String;
      To      : String;
      Force   : Boolean;
      Combine : Combine_Mode := Combine_Overwrite) return Boolean
   is
      Source   : constant String := Note_Of (Tree, From);
      Existing : constant String := Note_Of (Tree, To);
   begin
      if not Force and then Existing'Length > 0 then
         return True;
      end if;
      if Source'Length > 0 then
         Add_Note (Repo, Tree, To, Source, Combine);
      elsif Existing'Length > 0 then
         Add_Note (Repo, Tree, To, "", Combine);
      end if;
      return False;
   end Copy_Note;

   function Entries (Tree : Notes_Tree) return Note_Vectors.Vector is
      Result : Note_Vectors.Vector;
   begin
      for C in Tree.Notes.Iterate loop
         Result.Append
           (Note_Entry'
              (Commit    => To_Unbounded_String (Note_Maps.Key (C)),
               Note_Blob => To_Unbounded_String (Note_Maps.Element (C))));
      end loop;
      return Result;
   end Entries;

   ---------------------------------------------------------------------------
   --  Writing

   function Write_Tree
     (Repo : Version.Repository.Repository_Handle;
      Tree : Notes_Tree) return Version.Objects.Hex_Object_Id
   is
      Index : Version.Staging.Index_Entry_Vectors.Vector;

      Hex_Digits : constant String := "0123456789abcdef";

      --  git's determine_fanout: each on-disk fanout level is two levels of
      --  its 16-ary in-memory trie, and a level fans out when every one of
      --  its 16 slots is itself a subtree, i.e. when two or more notes
      --  share every possible next nibble under Prefix.
      function Fans_Out (Prefix : String) return Boolean is
      begin
         for D of Hex_Digits loop
            declare
               Sub   : constant String := Prefix & D;
               Count : Natural := 0;
            begin
               for C in Tree.Notes.Iterate loop
                  if Has_Prefix (Note_Maps.Key (C), Sub) then
                     Count := Count + 1;
                     exit when Count = 2;
                  end if;
               end loop;
               if Count < 2 then
                  return False;
               end if;
            end;
         end loop;
         return True;
      end Fans_Out;

      --  Emit the notes under Prefix (an even number of hex digits, one
      --  directory per pair) at the fanout Prefix implies, descending one
      --  more level where the heuristic says to.
      procedure Emit (Prefix : String) is
      begin
         if Fans_Out (Prefix) then
            for D1 of Hex_Digits loop
               for D2 of Hex_Digits loop
                  Emit (Prefix & D1 & D2);
               end loop;
            end loop;
            return;
         end if;

         for C in Tree.Notes.Iterate loop
            declare
               Key : constant String := Note_Maps.Key (C);
            begin
               if Has_Prefix (Key, Prefix) then
                  declare
                     Path : Unbounded_String;
                  begin
                     for K in Key'Range loop
                        if K > Key'First and then (K - Key'First) mod 2 = 0
                          and then K - Key'First <= Prefix'Length
                        then
                           Append (Path, '/');
                        end if;
                        Append (Path, Key (K));
                     end loop;
                     Index.Append
                       (Version.Staging.Index_Entry'
                          (Path  => Path,
                           Id    => To_Object_Id (Note_Maps.Element (C)),
                           Mode  => To_Unbounded_String ("100644"),
                           Stage => 0, Skip_Worktree => False,
                           Assume_Valid => False, Intent_To_Add => False));
                  end;
               end if;
            end;
         end loop;
      end Emit;
   begin
      Emit ("");
      Version.Staging.Sort_By_Path (Index);
      return Version.Write.Write_Tree_From_Index (Repo, Index);
   end Write_Tree;

   function Create_Notes_Commit
     (Repo    : Version.Repository.Repository_Handle;
      Tree    : Notes_Tree;
      Parents : Version.Objects.Object_Id_Vectors.Vector;
      Message : String) return Version.Objects.Hex_Object_Id
   is
      Tree_Id  : constant Version.Objects.Hex_Object_Id := Write_Tree (Repo, Tree);
      Actual   : Version.Objects.Object_Id_Vectors.Vector := Parents;
      Content  : Unbounded_String;
   begin
      if Actual.Is_Empty
        and then Version.Refs.Ref_Exists (Repo, To_String (Tree.Ref))
      then
         Actual.Append (Version.Refs.Resolve_Ref (Repo, To_String (Tree.Ref)));
      end if;
      --  git's commit_tree stores the message verbatim: a merge's
      --  "Merged notes from X into Y" has no final newline, while the
      --  subcommands' messages (and a conflicted merge's) end in one.
      Append (Content, "tree " & To_String (Tree_Id) & LF);
      for P of Actual loop
         Append (Content, "parent " & To_String (P) & LF);
      end loop;
      Append (Content, "author " & Version.Config.Author_Signature (Repo) & LF);
      Append (Content,
              "committer " & Version.Config.Committer_Signature (Repo) & LF);
      Append (Content, LF);
      Append (Content, Message);
      return Version.Write.Write_Object (Repo, "commit", To_String (Content));
   end Create_Notes_Commit;

   procedure Commit_Notes
     (Repo    : Version.Repository.Repository_Handle;
      Tree    : in out Notes_Tree;
      Message : String)
   is
      Ref : constant String := To_String (Tree.Ref);
      Old : Unbounded_String;
   begin
      if not Tree.Dirty then
         return;
      end if;
      if Version.Refs.Ref_Exists (Repo, Ref) then
         Old := To_Unbounded_String
           (To_String (Version.Refs.Resolve_Ref (Repo, Ref)));
      end if;

      declare
         --  git's commit_notes completes the message's last line.
         New_Commit : constant Version.Objects.Hex_Object_Id :=
           Create_Notes_Commit
             (Repo, Tree, Version.Objects.Object_Id_Vectors.Empty_Vector,
              (if Message'Length > 0 and then Message (Message'Last) /= LF
               then Message & LF else Message));
         Tx : Version.Ref_Transaction.Transaction;
      begin
         Version.Ref_Transaction.Start (Tx, Repo);
         Version.Ref_Transaction.Add_Update (Tx, Ref, New_Commit, To_String (Old));
         Version.Ref_Transaction.Commit (Tx);
         Version.Reflog.Append
           (Repo, Ref,
            (if Length (Old) > 0 then To_String (Old)
             else To_String (Version.Objects.Zero_Object_Id)),
            To_String (New_Commit), "notes: " & Message);
      end;
      Tree.Dirty := False;
   end Commit_Notes;

   function Prune_Candidates
     (Repo : Version.Repository.Repository_Handle;
      Tree : Notes_Tree) return Note_Vectors.Vector
   is
      Result : Note_Vectors.Vector;

      --  A note whose object is gone is unreachable annotation; git drops it.
      function Object_Exists (Hex : String) return Boolean is
         Ignored : constant Version.Objects.Git_Object :=
           Version.Objects.Read_Object (Repo, To_Object_Id (Hex));
         pragma Unreferenced (Ignored);
      begin
         return True;
      exception
         when others =>
            return False;
      end Object_Exists;
   begin
      for C in Tree.Notes.Iterate loop
         if not Object_Exists (Note_Maps.Key (C)) then
            Result.Append
              (Note_Entry'
                 (Commit    => To_Unbounded_String (Note_Maps.Key (C)),
                  Note_Blob => To_Unbounded_String (Note_Maps.Element (C))));
         end if;
      end loop;
      return Result;
   end Prune_Candidates;

   ---------------------------------------------------------------------------
   --  Conveniences

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

   procedure Add
     (Repo            : Version.Repository.Repository_Handle;
      Commit          : Version.Objects.Hex_Object_Id;
      Message         : String;
      Ref             : String := Default_Ref;
      Cleanup_Message : Boolean := True)
   is
      Tree : Notes_Tree;
      Blob : constant Version.Objects.Hex_Object_Id :=
        Version.Write.Write_Blob
          (Repo, (if Cleanup_Message then Cleanup (Message) else Message));
   begin
      Load (Repo, Qualify_Ref (Ref), Tree);
      Add_Note (Repo, Tree, To_String (Commit), To_String (Blob));
      Commit_Notes (Repo, Tree, "Notes added by 'git notes add'");
   end Add;

   function Show
     (Repo   : Version.Repository.Repository_Handle;
      Commit : Version.Objects.Hex_Object_Id;
      Ref    : String := Default_Ref)
      return String
   is
      Tree : Notes_Tree;
   begin
      Load (Repo, Qualify_Ref (Ref), Tree);
      return Blob_Text (Repo, Note_Of (Tree, To_String (Commit)));
   end Show;

   function List
     (Repo : Version.Repository.Repository_Handle;
      Ref  : String := Default_Ref)
      return Note_Vectors.Vector
   is
      Tree : Notes_Tree;
   begin
      Load (Repo, Qualify_Ref (Ref), Tree);
      return Entries (Tree);
   end List;

   function Has_Note
     (Repo   : Version.Repository.Repository_Handle;
      Commit : Version.Objects.Hex_Object_Id;
      Ref    : String := Default_Ref)
      return Boolean
   is
      Tree : Notes_Tree;
   begin
      Load (Repo, Qualify_Ref (Ref), Tree);
      return Note_Of (Tree, To_String (Commit))'Length > 0;
   end Has_Note;

   procedure Remove
     (Repo   : Version.Repository.Repository_Handle;
      Commit : Version.Objects.Hex_Object_Id;
      Ref    : String := Default_Ref)
   is
      Tree : Notes_Tree;
   begin
      Load (Repo, Qualify_Ref (Ref), Tree);
      if not Remove_Note (Tree, To_String (Commit)) then
         raise Ada.IO_Exceptions.Data_Error with
           "Object " & To_String (Commit) & " has no note";
      end if;
      Commit_Notes (Repo, Tree, "Notes removed by 'git notes remove'");
   end Remove;

   procedure Append
     (Repo            : Version.Repository.Repository_Handle;
      Commit          : Version.Objects.Hex_Object_Id;
      Message         : String;
      Ref             : String := Default_Ref;
      Cleanup_Message : Boolean := True)
   is
      Existing : constant String := Show (Repo, Commit, Ref);
   begin
      if Existing'Length = 0 then
         Add (Repo, Commit, Message, Ref, Cleanup_Message);
      else
         --  git separates an appended paragraph with a blank line. Cleanup
         --  normalises the existing note to a single trailing newline so the
         --  extra LF makes exactly that blank line; the joined result is then
         --  written verbatim when the caller supplied pre-assembled bytes.
         Add (Repo, Commit,
              Cleanup (Existing) & ASCII.LF & Message, Ref, Cleanup_Message);
      end if;
   end Append;

   procedure Copy
     (Repo  : Version.Repository.Repository_Handle;
      From  : Version.Objects.Hex_Object_Id;
      To    : Version.Objects.Hex_Object_Id;
      Force : Boolean := False;
      Ref   : String := Default_Ref)
   is
      Tree : Notes_Tree;
   begin
      Load (Repo, Qualify_Ref (Ref), Tree);
      if Note_Of (Tree, To_String (From))'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with
           "missing notes on source object " & To_String (From)
           & ". Cannot copy.";
      end if;
      if Copy_Note (Repo, Tree, To_String (From), To_String (To), Force) then
         raise Ada.IO_Exceptions.Data_Error with
           "Cannot copy notes. Found existing notes for object "
           & To_String (To) & ". Use '-f' to overwrite existing notes";
      end if;
      Commit_Notes (Repo, Tree, "Notes added by 'git notes copy'");
   end Copy;

   procedure Prune
     (Repo : Version.Repository.Repository_Handle;
      Ref  : String := Default_Ref)
   is
      Tree    : Notes_Tree;
      Removed : Boolean with Unreferenced;
   begin
      Load (Repo, Qualify_Ref (Ref), Tree);
      for E of Prune_Candidates (Repo, Tree) loop
         Removed := Remove_Note (Tree, To_String (E.Commit));
      end loop;
      Commit_Notes (Repo, Tree, "Notes removed by 'git notes prune'");
   end Prune;

end Version.Notes;
