with Ada.IO_Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

with Version.Files;
with Version.Ref_Names;
with Version.Refs;

--  The on-disk form is git's own `.git/rebase-merge/` directory, not a private
--  format: a rebase this tool pauses is the same object a paused `git rebase`
--  leaves behind, so `git status` reports it and `git rebase --continue` can
--  drive it to completion (and the reverse).
--
--  The todo files are authoritative for what remains to be done. What used to
--  be separate Commits/Actions/Execs fields is one ordered list of todo lines,
--  split across `done` (executed) and `git-rebase-todo` (pending) exactly as
--  git splits it; the accessors below re-derive the old view from that split.
package body Version.Rebase_State is
   use Version.Objects;

   LF : constant Character := Character'Val (10);

   Zero_Id : constant Version.Objects.Hex_Object_Id :=
     Version.Objects.Zero_Object_Id;

   function State_Dir
     (Repo : Version.Repository.Repository_Handle) return String is
     (Version.Files.Join
        (Version.Repository.Git_Dir (Repo), "rebase-merge"));

   function State_Path
     (Repo : Version.Repository.Repository_Handle; Name : String)
      return String is
     (Version.Files.Join (State_Dir (Repo), Name));

   function State_Exists
     (Repo : Version.Repository.Repository_Handle) return Boolean is
     (Version.Files.Is_Directory (State_Dir (Repo)));

   function Has_File
     (Repo : Version.Repository.Repository_Handle; Name : String)
      return Boolean is
     (Version.Files.Is_Ordinary_File (State_Path (Repo, Name)));

   procedure Put_File
     (Repo : Version.Repository.Repository_Handle; Name, Content : String) is
   begin
      Version.Files.Write_Binary_File_Atomic
        (Path => State_Path (Repo, Name), Content => Content);
   end Put_File;

   function Get_File
     (Repo : Version.Repository.Repository_Handle; Name : String)
      return String is
     (Version.Files.Read_Binary_File (State_Path (Repo, Name)));

   --  Every scalar git writes here is one line; the trailing newline is not
   --  part of the value.
   function Get_Line
     (Repo : Version.Repository.Repository_Handle; Name : String)
      return String
   is
      Raw  : constant String := Get_File (Repo, Name);
      Last : Natural := Raw'Last;
   begin
      while Last >= Raw'First
        and then (Raw (Last) = LF or else Raw (Last) = Character'Val (13))
      loop
         Last := Last - 1;
      end loop;
      return Raw (Raw'First .. Last);
   end Get_Line;

   procedure Require_Id (Text : String; Field : String) is
   begin
      if not Version.Objects.Is_Valid_Hex_Object_Id (Text) then
         raise Ada.IO_Exceptions.Data_Error with
           "malformed rebase state: " & Field;
      end if;
   end Require_Id;

   procedure Require_Text (Text : String; Field : String) is
   begin
      if Text'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with
           "malformed rebase state: " & Field;
      end if;

      for C of Text loop
         if C = Character'Val (0)
           or else C = LF
           or else C = Character'Val (13)
         then
            raise Ada.IO_Exceptions.Data_Error with
              "malformed rebase state: " & Field;
         end if;
      end loop;
   end Require_Text;

   procedure Require_Branch_Ref (Text : String) is
      Prefix : constant String := "refs/heads/";
   begin
      Require_Text (Text, "branch");
      Version.Ref_Names.Require_Ref_Name (Text);

      if Text'Length <= Prefix'Length
        or else Text (Text'First .. Text'First + Prefix'Length - 1) /= Prefix
      then
         raise Ada.IO_Exceptions.Data_Error with
           "malformed rebase state: branch";
      end if;
   end Require_Branch_Ref;

   --  msgnum/end are written for git's benefit but never read back: the split
   --  between `done` and `git-rebase-todo` is what says how far the rebase got,
   --  so the counters cannot drift out of agreement with the todo.
   function Natural_Image (Value : Natural) return String is
      Text : constant String := Natural'Image (Value);
   begin
      return Text (Text'First + 1 .. Text'Last);
   end Natural_Image;

   ---------------------------  todo line grammar  ---------------------------

   --  A todo line is `<verb> <argument> [# <subject>]`. Commit verbs carry a
   --  full object id (git writes 40 hex here, not an abbreviation, in both
   --  `done` and `git-rebase-todo`); `exec` carries the rest of the line as a
   --  shell command and no comment.
   --  Exec is the one command that is not part of the public Todo_Command
   --  grammar: it belongs to interactive rebase, not to topology.
   type Line_Kind is (Line_Commit, Line_Exec, Line_Label, Line_Reset,
                      Line_Merge);

   type Todo_Line is record
      Kind    : Line_Kind := Line_Commit;
      Action  : Rebase_Action := Pick;
      Id      : Version.Objects.Object_Id_Storage := Zero_Id;
      Command : Unbounded_String := Null_Unbounded_String;
      Label   : Unbounded_String := Null_Unbounded_String;
   end record;

   package Todo_Vectors is new Ada.Containers.Vectors
     (Index_Type => Natural, Element_Type => Todo_Line);

   function Action_Word (A : Rebase_Action) return String is
     (case A is
         when Pick => "pick", when Reword => "reword", when Edit => "edit");

   function Subject_Of
     (Repo : Version.Repository.Repository_Handle;
      Id   : Version.Objects.Hex_Object_Id) return String is
     (Version.Objects.Commit_Message_First_Line
        (Version.Objects.Read_Object (Repo, Id)))
   with Inline;

   function Render
     (Repo : Version.Repository.Repository_Handle;
      Item : Todo_Line) return String
   is
   begin
      case Item.Kind is
         when Line_Exec =>
            return "exec " & To_String (Item.Command);
         when Line_Commit =>
            declare
               --  The comment is what `git status` shows the user; an
               --  unreadable commit must not make the state unwritable.
               function Comment return String is
               begin
                  return " # " & Subject_Of (Repo, Item.Id);
               exception
                  when others =>
                     return "";
               end Comment;
            begin
               return Action_Word (Item.Action) & " "
                 & To_String (Item.Id) & Comment;
            end;
         when Line_Label =>
            return "label " & To_String (Item.Label);
         when Line_Reset =>
            return "reset " & To_String (Item.Label);
         when Line_Merge =>
            declare
               function Comment return String is
               begin
                  return " # " & Subject_Of (Repo, Item.Id);
               exception
                  when others =>
                     return "";
               end Comment;
            begin
               --  -C keeps the original merge's message and authorship, which
               --  is what makes the recreated merge the same commit in spirit.
               return "merge -C " & To_String (Item.Id) & " "
                 & To_String (Item.Label) & Comment;
            end;
      end case;
   end Render;

   function Parse_Todo (Text : String) return Todo_Vectors.Vector is
      Result : Todo_Vectors.Vector;
      First  : Natural := Text'First;
   begin
      while First <= Text'Last loop
         declare
            Last : Natural := First;
         begin
            while Last <= Text'Last and then Text (Last) /= LF loop
               Last := Last + 1;
            end loop;

            declare
               Line : constant String :=
                 (if Last > First then Text (First .. Last - 1) else "");
               Sp   : constant Natural := Ada.Strings.Fixed.Index (Line, " ");
            begin
               --  Blank lines and git's comment legend are not commands.
               if Line'Length = 0 or else Line (Line'First) = '#' then
                  null;
               elsif Sp = 0 then
                  raise Ada.IO_Exceptions.Data_Error with
                    "malformed rebase state: todo line";
               else
                  declare
                     Verb : constant String := Line (Line'First .. Sp - 1);
                     Rest : constant String := Line (Sp + 1 .. Line'Last);

                     --  Strip git's trailing ` # <subject>`; a command's own
                     --  text (exec) keeps everything after the verb.
                     function Argument return String is
                        Hash : constant Natural :=
                          Ada.Strings.Fixed.Index (Rest, " #");
                     begin
                        if Hash = 0 then
                           return Rest;
                        end if;
                        return Rest (Rest'First .. Hash - 1);
                     end Argument;
                  begin
                     --  git comments a reset with the commit the label
                     --  stands for ("reset branch-point # A"), so the label is
                     --  only the part before it.
                     if Verb = "label" or else Verb = "l" then
                        Require_Text (Argument, "label");
                        Result.Append
                          (Todo_Line'
                             (Kind  => Line_Label,
                              Label => To_Unbounded_String (Argument),
                              others => <>));
                     elsif Verb = "reset" or else Verb = "t" then
                        Require_Text (Argument, "reset");
                        Result.Append
                          (Todo_Line'
                             (Kind  => Line_Reset,
                              Label => To_Unbounded_String (Argument),
                              others => <>));
                     elsif Verb = "merge" or else Verb = "m" then
                        --  `merge -C <sha> <label> [# subject]`; the -c spelling
                        --  differs only in reopening the editor, which is not a
                        --  distinction a replay can act on.
                        declare
                           R : constant String :=
                             (if Rest'Length > 3
                                and then (Rest (Rest'First .. Rest'First + 2)
                                          = "-C " or else
                                          Rest (Rest'First .. Rest'First + 2)
                                          = "-c ")
                              then Rest (Rest'First + 3 .. Rest'Last)
                              else Rest);
                           Gap : constant Natural :=
                             Ada.Strings.Fixed.Index (R, " ");
                           Id_Text : constant String :=
                             (if Gap = 0 then R else R (R'First .. Gap - 1));
                           Rest_Of : constant String :=
                             (if Gap = 0 then "" else R (Gap + 1 .. R'Last));
                           Hash : constant Natural :=
                             Ada.Strings.Fixed.Index (Rest_Of, " #");
                           Lbl : constant String :=
                             (if Hash = 0 then Rest_Of
                              else Rest_Of (Rest_Of'First .. Hash - 1));
                        begin
                           Require_Id (Id_Text, "merge commit");
                           Require_Text (Lbl, "merge label");
                           Result.Append
                             (Todo_Line'
                                (Kind  => Line_Merge,
                                 Id    => Version.Objects.To_Object_Id (Id_Text),
                                 Label => To_Unbounded_String (Lbl),
                                 others => <>));
                        end;
                     elsif Verb = "exec" or else Verb = "x" then
                        Require_Text (Rest, "exec command");
                        Result.Append
                          (Todo_Line'
                             (Kind    => Line_Exec,
                              Action  => Pick,
                              Id      => Zero_Id,
                              Command => To_Unbounded_String (Rest),
                              Label   => Null_Unbounded_String));
                     else
                        declare
                           Arg : constant String := Argument;
                           Act : Rebase_Action;
                        begin
                           if Verb = "pick" or else Verb = "p" then
                              Act := Pick;
                           elsif Verb = "reword" or else Verb = "r" then
                              Act := Reword;
                           elsif Verb = "edit" or else Verb = "e" then
                              Act := Edit;
                           else
                              raise Ada.IO_Exceptions.Data_Error with
                                "malformed rebase state: todo command "
                                & Verb;
                           end if;

                           Require_Id (Arg, "todo commit");
                           Result.Append
                             (Todo_Line'
                                (Kind    => Line_Commit,
                                 Action  => Act,
                                 Id      => Version.Objects.To_Object_Id (Arg),
                                 Command => Null_Unbounded_String,
                                 Label   => Null_Unbounded_String));
                        end;
                     end if;
                  end;
               end if;
            end;

            First := Last + 1;
         end;
      end loop;

      return Result;
   end Parse_Todo;

   --  Rebuild the whole ordered command list from the caller's separate
   --  Commits/Actions/Execs view. An exec's After is the number of commits
   --  above it, which is exactly where it lands in this sequence.
   function Build_Todo
     (Commits : Commit_Vectors.Vector;
      Actions : Action_Vectors.Vector;
      Execs   : Exec_Vectors.Vector) return Todo_Vectors.Vector
   is
      Result : Todo_Vectors.Vector;

      function Action_At (I : Natural) return Rebase_Action is
        (if Actions.Is_Empty then Pick else Actions.Element (I));

      procedure Emit_Execs_After (N : Natural) is
      begin
         for E of Execs loop
            if E.After = N then
               Result.Append
                 (Todo_Line'
                    (Kind    => Line_Exec,
                     Action  => Pick,
                     Id      => Zero_Id,
                     Command => E.Command,
                     Label   => Null_Unbounded_String));
            end if;
         end loop;
      end Emit_Execs_After;
   begin
      Emit_Execs_After (0);

      if not Commits.Is_Empty then
         for I in Commits.First_Index .. Commits.Last_Index loop
            Result.Append
              (Todo_Line'
                 (Kind    => Line_Commit,
                  Action  => Action_At (I),
                  Id      => Commits.Element (I),
                  Command => Null_Unbounded_String,
                  Label   => Null_Unbounded_String));
            Emit_Execs_After (I + 1);
         end loop;
      end if;

      return Result;
   end Build_Todo;

   function Serialize
     (Repo  : Version.Repository.Repository_Handle;
      Items : Todo_Vectors.Vector;
      From  : Natural;
      To    : Integer) return String
   is
      Text : Unbounded_String;
   begin
      for I in From .. To loop
         Append (Text, Render (Repo, Items.Element (I)) & LF);
      end loop;
      return To_String (Text);
   end Serialize;

   --  How many todo lines precede the Nth commit and the Mth exec -- the split
   --  point between `done` and `git-rebase-todo`.
   function Split_Point
     (Items      : Todo_Vectors.Vector;
      Next_Index : Natural;
      Next_Exec  : Natural) return Natural
   is
      Commits_Seen : Natural := 0;
      Execs_Seen   : Natural := 0;
   begin
      if Items.Is_Empty then
         return 0;
      end if;

      for I in Items.First_Index .. Items.Last_Index loop
         case Items.Element (I).Kind is
            when Line_Commit =>
               exit when Commits_Seen >= Next_Index;
               Commits_Seen := Commits_Seen + 1;
            when Line_Exec =>
               exit when Execs_Seen >= Next_Exec;
               Execs_Seen := Execs_Seen + 1;
            when Line_Label | Line_Reset | Line_Merge =>
               --  Only reachable for a merges todo, which splits by an
               --  explicit command count instead of these counters.
               null;
         end case;
      end loop;

      return Commits_Seen + Execs_Seen;
   end Split_Point;

   -------------------------------  writing  --------------------------------

   procedure Write_State
     (Repo                : Version.Repository.Repository_Handle;
      Branch_Ref          : String;
      Original_Head       : Version.Objects.Hex_Object_Id;
      Target_Head         : Version.Objects.Hex_Object_Id;
      Current_Replay_Head : Version.Objects.Hex_Object_Id;
      Next_Index          : Natural;
      Commits             : Commit_Vectors.Vector;
      Paused              : Boolean := False;
      Current_Commit      : String := "";
      Actions             : Action_Vectors.Vector := Action_Vectors.Empty_Vector;
      Execs               : Exec_Vectors.Vector := Exec_Vectors.Empty_Vector;
      Next_Exec           : Natural := 0;
      Pause_Reason        : Pause_Kind := Pause_Conflict;
      Mode                : Rebase_Mode := Mode_Linear;
      Rebased_Map         : Map_Vectors.Vector := Map_Vectors.Empty_Vector)
   is
      pragma Unreferenced (Current_Replay_Head);
      --  Under git's model the replay head IS HEAD, which the rebase driver
      --  detaches and advances; there is no separate field to store, and
      --  Read_State reads it back from HEAD.

      Items : constant Todo_Vectors.Vector :=
        Build_Todo (Commits, Actions, Execs);

      --  git counts the command it stopped on as done -- it is the "last
      --  command done" its status reports -- even though the commit is not
      --  applied yet. Our cursor still points at it, so the split runs one
      --  line further when stopped on a commit; Read_State undoes this.
      Stopped_On_Commit : constant Boolean :=
        Paused and then Pause_Reason /= Pause_Exec;
      Split : constant Natural :=
        Split_Point
          (Items,
           Next_Index + (if Stopped_On_Commit then 1 else 0),
           Next_Exec);
   begin
      Require_Branch_Ref (Branch_Ref);
      Require_Id (To_String (Original_Head), "original head");
      Require_Id (To_String (Target_Head), "target head");

      if Paused and then Pause_Reason /= Pause_Exec then
         Require_Id (Current_Commit, "current commit");
      elsif (not Paused or else Pause_Reason = Pause_Exec)
        and then Current_Commit'Length /= 0
      then
         raise Ada.IO_Exceptions.Data_Error with
           "malformed rebase state: current commit without commit-anchored"
           & " pause";
      end if;

      if not Commits.Is_Empty then
         for I in Commits.First_Index .. Commits.Last_Index loop
            Require_Id (To_String (Commits.Element (I)), "commit");
         end loop;
      end if;

      if not Actions.Is_Empty
        and then Natural (Actions.Length) /= Natural (Commits.Length)
      then
         raise Ada.IO_Exceptions.Data_Error with
           "malformed rebase state: action count";
      end if;

      if Next_Index > Natural (Commits.Length) then
         raise Ada.IO_Exceptions.Data_Error with
           "malformed rebase state: next index";
      end if;

      if not Execs.Is_Empty then
         for I in Execs.First_Index .. Execs.Last_Index loop
            if Execs.Element (I).After > Natural (Commits.Length) then
               raise Ada.IO_Exceptions.Data_Error with
                 "malformed rebase state: exec position";
            end if;
            Require_Text
              (To_String (Execs.Element (I).Command), "exec command");
         end loop;
      end if;

      if Next_Exec > Natural (Execs.Length) then
         raise Ada.IO_Exceptions.Data_Error with
           "malformed rebase state: next exec";
      end if;

      if Paused and then Pause_Reason /= Pause_Exec then
         if Next_Index >= Natural (Commits.Length)
           or else Commits.Element (Commits.First_Index + Next_Index)
             /= Version.Objects.To_Object_Id (Current_Commit)
         then
            raise Ada.IO_Exceptions.Data_Error with
              "malformed rebase state: current commit";
         end if;
      end if;

      if Paused and then Pause_Reason = Pause_Exec
        and then Next_Exec >= Natural (Execs.Length)
      then
         raise Ada.IO_Exceptions.Data_Error with
           "malformed rebase state: exec pause without exec";
      end if;

      Version.Files.Create_Directory_If_Missing (State_Dir (Repo));

      Put_File (Repo, "head-name", Branch_Ref & LF);
      Put_File (Repo, "onto", To_String (Target_Head) & LF);
      Put_File (Repo, "orig-head", To_String (Original_Head) & LF);

      --  git drives every rebase through the sequencer now, so it writes this
      --  flag even for a plain `git rebase`; `status` keys its "interactive
      --  rebase in progress" wording off it.
      Put_File (Repo, "interactive", "");
      Put_File (Repo, "no-reschedule-failed-exec", "");

      Put_File
        (Repo, "done",
         Serialize (Repo, Items, 0, Split - 1));
      Put_File
        (Repo, "git-rebase-todo",
         Serialize (Repo, Items, Split, Integer (Items.Length) - 1));

      if not Has_File (Repo, "git-rebase-todo.backup") then
         Put_File
           (Repo, "git-rebase-todo.backup",
            Serialize (Repo, Items, 0, Integer (Items.Length) - 1));
      end if;

      Put_File (Repo, "msgnum", Natural_Image (Next_Index) & LF);
      Put_File (Repo, "end", Natural_Image (Natural (Commits.Length)) & LF);

      if Paused and then Pause_Reason /= Pause_Exec then
         Put_File (Repo, "stopped-sha", Current_Commit & LF);
         --  REBASE_HEAD names the commit being replayed, so `git rev-parse
         --  REBASE_HEAD` and the `REBASE_HEAD` revision suffix resolve.
         Version.Files.Write_Binary_File_Atomic
           (Path    => Version.Files.Join
                         (Version.Repository.Git_Dir (Repo), "REBASE_HEAD"),
            Content => Current_Commit & LF);
      else
         Version.Files.Delete_File_If_Exists (State_Path (Repo, "stopped-sha"));
         Version.Files.Delete_File_If_Exists
           (Version.Files.Join
              (Version.Repository.Git_Dir (Repo), "REBASE_HEAD"));
      end if;

      --  git marks an edit stop -- where the commit is already made and the
      --  user is expected to `commit --amend` -- with this flag; a conflict
      --  stop has no commit to amend and does not get one.
      if Paused and then Pause_Reason = Pause_Edit then
         Put_File (Repo, "amend", "");
      else
         Version.Files.Delete_File_If_Exists (State_Path (Repo, "amend"));
      end if;

      --  `--rebase-merges` topology has no representation in git's todo until
      --  the label/reset/merge commands are ported; until then it rides in a
      --  file of our own beside git's, which git ignores.
      if Mode = Mode_Merges or else not Rebased_Map.Is_Empty then
         declare
            Text : Unbounded_String;
         begin
            Append (Text, "merges" & LF);
            for I in Rebased_Map.First_Index .. Rebased_Map.Last_Index loop
               Append
                 (Text,
                  To_String (Rebased_Map.Element (I).Original) & " "
                  & To_String (Rebased_Map.Element (I).Rebased) & LF);
            end loop;
            Put_File (Repo, "version-merges", To_String (Text));
         end;
      else
         Version.Files.Delete_File_If_Exists
           (State_Path (Repo, "version-merges"));
      end if;
   end Write_State;

   procedure Write_Resume_Info
     (Repo        : Version.Repository.Repository_Handle;
      Author_Line : String;
      Message     : String;
      Patch       : String)
   is
      --  "Name <email> <ts> <tz>" -> git's three shell assignments. git quotes
      --  each value in single quotes and writes the date in its raw
      --  "@<epoch> <tz>" form, which is what it parses back.
      function Author_Script return String is
         Open  : constant Natural := Ada.Strings.Fixed.Index (Author_Line, "<");
         Close : constant Natural := Ada.Strings.Fixed.Index (Author_Line, ">");

         function Quoted (Value : String) return String is
            Text : Unbounded_String;
         begin
            --  A single quote inside a single-quoted shell word is written by
            --  closing, escaping and reopening it.
            for C of Value loop
               if C = ''' then
                  Append (Text, "'\''");
               else
                  Append (Text, C);
               end if;
            end loop;
            return "'" & To_String (Text) & "'";
         end Quoted;
      begin
         if Open = 0 or else Close = 0 or else Close < Open then
            return "";
         end if;

         declare
            Name  : constant String :=
              Ada.Strings.Fixed.Trim
                (Author_Line (Author_Line'First .. Open - 1),
                 Ada.Strings.Both);
            Email : constant String := Author_Line (Open + 1 .. Close - 1);
            Date  : constant String :=
              Ada.Strings.Fixed.Trim
                (Author_Line (Close + 1 .. Author_Line'Last),
                 Ada.Strings.Both);
         begin
            return "GIT_AUTHOR_NAME=" & Quoted (Name) & LF
              & "GIT_AUTHOR_EMAIL=" & Quoted (Email) & LF
              & "GIT_AUTHOR_DATE=" & Quoted ("@" & Date) & LF;
         end;
      end Author_Script;
   begin
      if not State_Exists (Repo) then
         return;
      end if;

      Put_File (Repo, "author-script", Author_Script);
      Put_File (Repo, "message", Message);
      Put_File (Repo, "patch", Patch);
   end Write_Resume_Info;

   procedure Write_Merges_State
     (Repo           : Version.Repository.Repository_Handle;
      Branch_Ref     : String;
      Original_Head  : Version.Objects.Hex_Object_Id;
      Target_Head    : Version.Objects.Hex_Object_Id;
      Todo           : Todo_Command_Vectors.Vector;
      Done_Count     : Natural;
      Paused         : Boolean := False;
      Current_Commit : String := "")
   is
      Items : Todo_Vectors.Vector;
      --  As in linear mode, git counts the command it stopped on as done: it
      --  is the "last command done" its status reports, even though the
      --  commit is not applied. Read_State takes the extra one back off.
      Split : constant Natural :=
        Natural'Min (Done_Count + (if Paused then 1 else 0),
                     Natural (Todo.Length));
      Picks : Natural := 0;
   begin
      Require_Branch_Ref (Branch_Ref);
      Require_Id (To_String (Original_Head), "original head");
      Require_Id (To_String (Target_Head), "target head");

      if Done_Count > Natural (Todo.Length) then
         raise Ada.IO_Exceptions.Data_Error with
           "malformed rebase state: done count";
      end if;

      for C of Todo loop
         case C.Kind is
            when Cmd_Pick =>
               Require_Id (To_String (C.Id), "commit");
               Picks := Picks + 1;
               Items.Append
                 (Todo_Line'
                    (Kind    => Line_Commit,
                     Action  => C.Action,
                     Id      => C.Id,
                     Command => Null_Unbounded_String,
                     Label   => Null_Unbounded_String));
            when Cmd_Label =>
               Require_Text (To_String (C.Label), "label");
               Items.Append
                 (Todo_Line'
                    (Kind => Line_Label, Label => C.Label, others => <>));
            when Cmd_Reset =>
               Require_Text (To_String (C.Label), "reset");
               Items.Append
                 (Todo_Line'
                    (Kind => Line_Reset, Label => C.Label, others => <>));
            when Cmd_Merge =>
               Require_Id (To_String (C.Id), "merge commit");
               Require_Text (To_String (C.Label), "merge label");
               Picks := Picks + 1;
               Items.Append
                 (Todo_Line'
                    (Kind  => Line_Merge,
                     Id    => C.Id,
                     Label => C.Label,
                     others => <>));
         end case;
      end loop;

      Version.Files.Create_Directory_If_Missing (State_Dir (Repo));

      Put_File (Repo, "head-name", Branch_Ref & LF);
      Put_File (Repo, "onto", To_String (Target_Head) & LF);
      Put_File (Repo, "orig-head", To_String (Original_Head) & LF);
      Put_File (Repo, "interactive", "");
      Put_File (Repo, "no-reschedule-failed-exec", "");

      Put_File (Repo, "done", Serialize (Repo, Items, 0, Split - 1));
      Put_File
        (Repo, "git-rebase-todo",
         Serialize (Repo, Items, Split, Integer (Items.Length) - 1));

      if not Has_File (Repo, "git-rebase-todo.backup") then
         Put_File
           (Repo, "git-rebase-todo.backup",
            Serialize (Repo, Items, 0, Integer (Items.Length) - 1));
      end if;

      --  msgnum/end count commits, not commands.
      declare
         Done_Picks : Natural := 0;
      begin
         for I in 0 .. Split - 1 loop
            if Items.Element (I).Kind in Line_Commit | Line_Merge then
               Done_Picks := Done_Picks + 1;
            end if;
         end loop;
         Put_File (Repo, "msgnum", Natural_Image (Done_Picks) & LF);
      end;
      Put_File (Repo, "end", Natural_Image (Picks) & LF);

      if Paused and then Current_Commit'Length > 0 then
         Require_Id (Current_Commit, "current commit");
         Put_File (Repo, "stopped-sha", Current_Commit & LF);
         Version.Files.Write_Binary_File_Atomic
           (Path    => Version.Files.Join
                         (Version.Repository.Git_Dir (Repo), "REBASE_HEAD"),
            Content => Current_Commit & LF);
      else
         Version.Files.Delete_File_If_Exists (State_Path (Repo, "stopped-sha"));
         Version.Files.Delete_File_If_Exists
           (Version.Files.Join
              (Version.Repository.Git_Dir (Repo), "REBASE_HEAD"));
      end if;

      Version.Files.Delete_File_If_Exists (State_Path (Repo, "amend"));
      --  The topology now lives in the todo itself, so the sidecar that used
      --  to carry it is not written -- and is removed if an older rebase left
      --  one behind.
      Version.Files.Delete_File_If_Exists
        (State_Path (Repo, "version-merges"));
   end Write_Merges_State;

   function Todo (State : Rebase_State) return Todo_Command_Vectors.Vector is
   begin
      return State.Todo_Value;
   end Todo;

   function Done_Count (State : Rebase_State) return Natural is
   begin
      return State.Done_Count_Value;
   end Done_Count;

   -------------------------------  reading  --------------------------------

   function Read_State
     (Repo : Version.Repository.Repository_Handle)
      return Rebase_State
   is
      State : Rebase_State;
   begin
      if not State_Exists (Repo) then
         raise Ada.IO_Exceptions.Data_Error with "no rebase in progress";
      end if;

      declare
         Branch_Text : constant String := Get_Line (Repo, "head-name");
      begin
         Require_Branch_Ref (Branch_Text);
         State.Branch_Ref_Value := To_Unbounded_String (Branch_Text);
      end;

      declare
         Onto_Text : constant String := Get_Line (Repo, "onto");
         Orig_Text : constant String := Get_Line (Repo, "orig-head");
      begin
         Require_Id (Onto_Text, "target head");
         Require_Id (Orig_Text, "original head");
         State.Target_Head_Value := Version.Objects.To_Object_Id (Onto_Text);
         State.Original_Head_Value := Version.Objects.To_Object_Id (Orig_Text);
      end;

      --  HEAD is the replay head: the rebase detaches it at `onto` and
      --  advances it commit by commit, exactly as git does.
      declare
         Head_Text : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         State.Current_Replay_Head_Value :=
           (if Version.Objects.Is_Valid_Hex_Object_Id (Head_Text)
            then Version.Objects.To_Object_Id (Head_Text)
            else State.Target_Head_Value);
      end;

      declare
         Done_Items : constant Todo_Vectors.Vector :=
           Parse_Todo (Get_File (Repo, "done"));
         Todo_Items : constant Todo_Vectors.Vector :=
           Parse_Todo (Get_File (Repo, "git-rebase-todo"));

         procedure Absorb (Items : Todo_Vectors.Vector; Executed : Boolean) is
         begin
            for Item of Items loop
               --  Every command, in order, is also kept as the public todo:
               --  that is the only view that can express a merges topology,
               --  while Commits/Actions stay the flat view linear mode uses.
               case Item.Kind is
                  when Line_Commit =>
                     State.Todo_Value.Append
                       (Todo_Command'
                          (Kind   => Cmd_Pick,
                           Action => Item.Action,
                           Id     => Item.Id,
                           Label  => Null_Unbounded_String));
                     State.Commits_Value.Append (Item.Id);
                     State.Actions_Value.Append (Item.Action);
                     if Executed then
                        State.Next_Index_Value := State.Next_Index_Value + 1;
                     end if;
                  when Line_Merge =>
                     State.Todo_Value.Append
                       (Todo_Command'
                          (Kind   => Cmd_Merge,
                           Action => Pick,
                           Id     => Item.Id,
                           Label  => Item.Label));
                     State.Mode_Value := Mode_Merges;
                     State.Commits_Value.Append (Item.Id);
                     State.Actions_Value.Append (Pick);
                     if Executed then
                        State.Next_Index_Value := State.Next_Index_Value + 1;
                     end if;
                  when Line_Label | Line_Reset =>
                     State.Todo_Value.Append
                       (Todo_Command'
                          (Kind   => (if Item.Kind = Line_Label
                                      then Cmd_Label else Cmd_Reset),
                           Action => Pick,
                           Id     => Zero_Id,
                           Label  => Item.Label));
                     State.Mode_Value := Mode_Merges;
                  when Line_Exec =>
                     State.Execs_Value.Append
                       (Exec_Step'
                          (After   => Natural (State.Commits_Value.Length),
                           Command => Item.Command));
                     if Executed then
                        State.Next_Exec_Value := State.Next_Exec_Value + 1;
                     end if;
               end case;

               if Executed then
                  State.Done_Count_Value := State.Done_Count_Value + 1;
               end if;
            end loop;
         end Absorb;
      begin
         Absorb (Done_Items, Executed => True);
         Absorb (Todo_Items, Executed => False);
      end;

      --  A rebase-merge directory only exists while a rebase is under way, and
      --  this tool only ever reads it back when stopped.
      State.Paused_Value := True;

      if Has_File (Repo, "stopped-sha") then
         declare
            Text : constant String := Get_Line (Repo, "stopped-sha");
         begin
            Require_Id (Text, "current commit");
            State.Current_Commit_Value := Version.Objects.To_Object_Id (Text);
            State.Pause_Reason_Value :=
              (if Has_File (Repo, "amend") then Pause_Edit else Pause_Conflict);

            --  The stopped command sits in `done` but has not been applied, so
            --  the resume cursor is one short of what `done` counts.
            if State.Next_Index_Value > 0 then
               State.Next_Index_Value := State.Next_Index_Value - 1;
            end if;
            if State.Done_Count_Value > 0 then
               State.Done_Count_Value := State.Done_Count_Value - 1;
            end if;
         end;
      else
         State.Current_Commit_Value := Zero_Id;
         State.Pause_Reason_Value := Pause_Exec;
      end if;

      if Has_File (Repo, "version-merges") then
         State.Mode_Value := Mode_Merges;
         declare
            Text  : constant String := Get_File (Repo, "version-merges");
            First : Natural := Text'First;
            Line_No : Natural := 0;
         begin
            while First <= Text'Last loop
               declare
                  Last : Natural := First;
               begin
                  while Last <= Text'Last and then Text (Last) /= LF loop
                     Last := Last + 1;
                  end loop;

                  declare
                     Line : constant String :=
                       (if Last > First then Text (First .. Last - 1) else "");
                     Sp   : constant Natural :=
                       Ada.Strings.Fixed.Index (Line, " ");
                  begin
                     if Line_No > 0 and then Line'Length > 0 then
                        if Sp = 0 then
                           raise Ada.IO_Exceptions.Data_Error with
                             "malformed rebase state: map pair";
                        end if;
                        State.Rebased_Map_Value.Append
                          (Map_Pair'
                             (Original => Version.Objects.To_Object_Id
                                            (Line (Line'First .. Sp - 1)),
                              Rebased  => Version.Objects.To_Object_Id
                                            (Line (Sp + 1 .. Line'Last))));
                     end if;
                  end;

                  Line_No := Line_No + 1;
                  First := Last + 1;
               end;
            end loop;
         end;
      end if;

      --  Linear mode alone can assert that the cursor lands on the stopped
      --  commit: a merges todo interleaves label/reset commands, so its
      --  commit cursor and its command cursor advance at different rates.
      if State.Pause_Reason_Value /= Pause_Exec
        and then State.Mode_Value = Mode_Linear
      then
         if State.Next_Index_Value >= Natural (State.Commits_Value.Length)
           or else State.Commits_Value.Element
             (State.Commits_Value.First_Index + State.Next_Index_Value)
               /= State.Current_Commit_Value
         then
            raise Ada.IO_Exceptions.Data_Error with
              "malformed rebase state: current commit";
         end if;
      end if;

      return State;
   end Read_State;

   procedure Clear_State
     (Repo : Version.Repository.Repository_Handle) is
   begin
      Version.Files.Delete_Directory_Tree_If_Exists (State_Dir (Repo));
      Version.Files.Delete_File_If_Exists
        (Version.Files.Join
           (Version.Repository.Git_Dir (Repo), "REBASE_HEAD"));
   end Clear_State;

   function Branch_Ref (State : Rebase_State) return String is
   begin
      return To_String (State.Branch_Ref_Value);
   end Branch_Ref;

   function Original_Head
     (State : Rebase_State) return Version.Objects.Hex_Object_Id is
   begin
      return State.Original_Head_Value;
   end Original_Head;

   function Target_Head
     (State : Rebase_State) return Version.Objects.Hex_Object_Id is
   begin
      return State.Target_Head_Value;
   end Target_Head;

   function Current_Replay_Head
     (State : Rebase_State) return Version.Objects.Hex_Object_Id is
   begin
      return State.Current_Replay_Head_Value;
   end Current_Replay_Head;

   function Next_Index (State : Rebase_State) return Natural is
   begin
      return State.Next_Index_Value;
   end Next_Index;

   function Total_Commits (State : Rebase_State) return Natural is
   begin
      return Natural (State.Commits_Value.Length);
   end Total_Commits;

   function Commits (State : Rebase_State) return Commit_Vectors.Vector is
   begin
      return State.Commits_Value;
   end Commits;

   function Actions (State : Rebase_State) return Action_Vectors.Vector is
   begin
      return State.Actions_Value;
   end Actions;

   function Paused (State : Rebase_State) return Boolean is
   begin
      return State.Paused_Value;
   end Paused;

   function Current_Commit
     (State : Rebase_State) return Version.Objects.Hex_Object_Id is
   begin
      return State.Current_Commit_Value;
   end Current_Commit;

   function Execs (State : Rebase_State) return Exec_Vectors.Vector is
   begin
      return State.Execs_Value;
   end Execs;

   function Next_Exec (State : Rebase_State) return Natural is
   begin
      return State.Next_Exec_Value;
   end Next_Exec;

   function Pause_Reason (State : Rebase_State) return Pause_Kind is
   begin
      return State.Pause_Reason_Value;
   end Pause_Reason;

   function Mode (State : Rebase_State) return Rebase_Mode is
   begin
      return State.Mode_Value;
   end Mode;

   function Rebased_Map (State : Rebase_State) return Map_Vectors.Vector is
   begin
      return State.Rebased_Map_Value;
   end Rebased_Map;

end Version.Rebase_State;
