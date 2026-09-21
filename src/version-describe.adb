with Ada.Containers.Ordered_Sets;
with Ada.Containers.Vectors;
with Ada.Exceptions;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;
with Interfaces;

with Version.History;
with Version.Object_Cache;
with Version.Ref_Format;
with Version.Refs;
with Version.Revisions;
with Version.Tree_Cache;

package body Version.Describe is
   use Version.Objects;
   use type Interfaces.Unsigned_32;

   LF : constant Character := Character'Val (10);

   function Img (N : Integer) return String is
     (Ada.Strings.Fixed.Trim (Integer'Image (N), Ada.Strings.Left));

   function Has_Prefix (Text, Prefix : String) return Boolean is
     (Text'Length >= Prefix'Length
      and then Text (Text'First .. Text'First + Prefix'Length - 1) = Prefix);

   --  git's wildmatch without WM_PATHNAME: `*` and `?` cross '/', `[...]`
   --  classes with `!`/`^` negation and ranges, `\` escapes.
   function Wildmatch (Pattern, Text : String) return Boolean is
      function M (P, T : Natural) return Boolean is
      begin
         if P > Pattern'Last then
            return T > Text'Last;
         end if;
         case Pattern (P) is
            when '*' =>
               declare
                  Q : Natural := P;
               begin
                  while Q <= Pattern'Last and then Pattern (Q) = '*' loop
                     Q := Q + 1;
                  end loop;
                  if Q > Pattern'Last then
                     return True;
                  end if;
                  for K in T .. Text'Last + 1 loop
                     if M (Q, K) then
                        return True;
                     end if;
                  end loop;
                  return False;
               end;
            when '?' =>
               return T <= Text'Last and then M (P + 1, T + 1);
            when '[' =>
               if T > Text'Last then
                  return False;
               end if;
               declare
                  Q       : Natural := P + 1;
                  Negate  : Boolean := False;
                  Matched : Boolean := False;
                  C       : constant Character := Text (T);
               begin
                  if Q <= Pattern'Last
                    and then (Pattern (Q) = '!' or else Pattern (Q) = '^')
                  then
                     Negate := True;
                     Q := Q + 1;
                  end if;
                  --  A ']' first is literal.
                  if Q <= Pattern'Last and then Pattern (Q) = ']' then
                     Matched := C = ']';
                     Q := Q + 1;
                  end if;
                  while Q <= Pattern'Last and then Pattern (Q) /= ']' loop
                     declare
                        Lo : Character := Pattern (Q);
                     begin
                        if Lo = '\' and then Q < Pattern'Last then
                           Q := Q + 1;
                           Lo := Pattern (Q);
                        end if;
                        if Q + 2 <= Pattern'Last and then Pattern (Q + 1) = '-'
                          and then Pattern (Q + 2) /= ']'
                        then
                           declare
                              Hi : Character := Pattern (Q + 2);
                           begin
                              if Hi = '\' and then Q + 3 <= Pattern'Last then
                                 Hi := Pattern (Q + 3);
                                 Q := Q + 1;
                              end if;
                              if C >= Lo and then C <= Hi then
                                 Matched := True;
                              end if;
                              Q := Q + 3;
                           end;
                        else
                           if C = Lo then
                              Matched := True;
                           end if;
                           Q := Q + 1;
                        end if;
                     end;
                  end loop;
                  if Q > Pattern'Last then
                     --  No closing bracket: the '[' is literal.
                     return C = '[' and then M (P + 1, T + 1);
                  end if;
                  if Matched = Negate then
                     return False;
                  end if;
                  return M (Q + 1, T + 1);
               end;
            when '\' =>
               if P < Pattern'Last then
                  return T <= Text'Last and then Text (T) = Pattern (P + 1)
                    and then M (P + 2, T + 1);
               end if;
               return T <= Text'Last and then Text (T) = '\'
                 and then M (P + 1, T + 1);
            when others =>
               return T <= Text'Last and then Text (T) = Pattern (P)
                 and then M (P + 1, T + 1);
         end case;
      end M;
   begin
      return M (Pattern'First, Text'First);
   end Wildmatch;

   --  The value of the tag object header Key ("tagger", "tag") in Content.
   function Tag_Header (Content : String; Key : String) return String is
      Start : Natural := Ada.Strings.Fixed.Index (Content, LF & Key & " ");
      Stop  : Natural;
   begin
      if Start = 0 then
         if Has_Prefix (Content, Key & " ") then
            Start := Content'First - 1;
         else
            return "";
         end if;
      end if;
      Start := Start + Key'Length + 2;
      Stop := Ada.Strings.Fixed.Index (Content (Start .. Content'Last), "" & LF);
      return Content (Start .. (if Stop = 0 then Content'Last else Stop - 1));
   end Tag_Header;

   --  The tagger timestamp of a tag object's content.
   function Tagger_Time (Content : String) return Long_Long_Integer is
      Ident : constant String := Tag_Header (Content, "tagger");
      Last_Sp, Prev_Sp : Natural := 0;
   begin
      for I in Ident'Range loop
         if Ident (I) = ' ' then
            Prev_Sp := Last_Sp;
            Last_Sp := I;
         end if;
      end loop;
      if Prev_Sp = 0 or else Last_Sp <= Prev_Sp + 1 then
         return 0;
      end if;
      return Long_Long_Integer'Value (Ident (Prev_Sp + 1 .. Last_Sp - 1));
   exception
      when others =>
         return 0;
   end Tagger_Time;

   ---------------------------------------------------------------------
   --  The name table (get_name / add_to_known_names)
   ---------------------------------------------------------------------

   function Load_Names
     (Repo    : Version.Repository.Repository_Handle;
      Options : Describe_Options) return Name_Table
   is
      Table       : Name_Table;
      Objects     : Version.Object_Cache.Object_Cache;
      No_Patterns : Version.Ref_Format.String_Vectors.Vector;

      procedure Add
        (Path     : String;
         Peeled   : Object_Id_Storage;
         Prio     : Natural;
         Id       : Object_Id_Storage;
         Tag_Name : String;
         Date     : Long_Long_Integer)
      is
         Cur     : constant Name_Maps.Cursor := Table.Names.Find (Peeled);
         Replace : Boolean;
      begin
         if not Name_Maps.Has_Element (Cur) then
            Replace := True;
         else
            declare
               E : constant Commit_Name := Name_Maps.Element (Cur);
            begin
               if E.Prio < Prio then
                  Replace := True;
               elsif E.Prio = 2 and then Prio = 2 then
                  --  Two annotated tags on one commit: the newer tagger
                  --  date wins.
                  Replace := E.Tagger_Date < Date;
               else
                  Replace := False;
               end if;
            end;
         end if;
         if Replace then
            Table.Names.Include
              (Peeled,
               Commit_Name'
                 (Peeled      => Peeled,
                  Id          => Id,
                  Path        => To_Unbounded_String (Path),
                  Prio        => Prio,
                  Tag_Name    => To_Unbounded_String (Tag_Name),
                  Tagger_Date => Date,
                  others      => <>));
         end if;
      end Add;

      Refnames : constant Version.Ref_Format.String_Vectors.Vector :=
        Version.Ref_Format.For_Each_Ref
          (Repo, No_Patterns, Format => "%(refname)");
   begin
      for Refname of Refnames loop
         declare
            Is_Tag     : constant Boolean := Has_Prefix (Refname, "refs/tags/");
            Have_Pat   : constant Boolean :=
              not Options.Patterns.Is_Empty
              or else not Options.Excludes.Is_Empty;
            Accept_Ref : Boolean := True;
            Match_From : Natural := 0;   --  index of path_to_match, 0 = none
         begin
            if Is_Tag then
               Match_From := Refname'First + 10;
            elsif Options.All_Refs then
               --  With patterns, only refs of a known kind take part.
               if Have_Pat then
                  if Has_Prefix (Refname, "refs/heads/") then
                     Match_From := Refname'First + 11;
                  elsif Has_Prefix (Refname, "refs/remotes/") then
                     Match_From := Refname'First + 13;
                  else
                     Accept_Ref := False;
                  end if;
               end if;
            else
               Accept_Ref := False;
            end if;

            if Accept_Ref and then Have_Pat then
               declare
                  Sub : constant String :=
                    (if Match_From = 0 then ""
                     else Refname (Match_From .. Refname'Last));
               begin
                  for X of Options.Excludes loop
                     if Wildmatch (X, Sub) then
                        Accept_Ref := False;
                        exit;
                     end if;
                  end loop;
                  if Accept_Ref and then not Options.Patterns.Is_Empty then
                     Accept_Ref := False;
                     for P of Options.Patterns loop
                        if Wildmatch (P, Sub) then
                           Accept_Ref := True;
                           exit;
                        end if;
                     end loop;
                  end if;
               end;
            end if;

            if Accept_Ref then
               declare
                  Id        : constant Object_Id_Storage :=
                    Version.Refs.Resolve_Ref (Repo, Refname);
                  Peeled    : Object_Id_Storage := Id;
                  Annotated : Boolean := False;
                  Tag_Name  : Unbounded_String;
                  Date      : Long_Long_Integer := 0;
                  Guard     : Natural := 0;
               begin
                  --  Peel through tag objects to what they finally name.
                  loop
                     declare
                        Obj : constant Git_Object :=
                          Version.Object_Cache.Read_Object (Repo, Objects, Peeled);
                     begin
                        exit when Kind (Obj) /= Tag_Object;
                        if not Annotated then
                           Tag_Name :=
                             To_Unbounded_String (Tag_Header (Content (Obj), "tag"));
                           Date := Tagger_Time (Content (Obj));
                        end if;
                        Annotated := True;
                        Peeled := Tag_Target_Id (Obj);
                     end;
                     Guard := Guard + 1;
                     exit when Guard > 32;
                  end loop;
                  Add
                    (Path     =>
                       (if Options.All_Refs
                        then Refname (Refname'First + 5 .. Refname'Last)
                        else Refname (Refname'First + 10 .. Refname'Last)),
                     Peeled   => Peeled,
                     Prio     => (if Annotated then 2 elsif Is_Tag then 1 else 0),
                     Id       => Id,
                     Tag_Name => To_String (Tag_Name),
                     Date     => Date);
               exception
                  when Ada.IO_Exceptions.Data_Error
                     | Ada.IO_Exceptions.Name_Error =>
                     --  A broken ref is skipped, as git's iteration skips it.
                     null;
               end;
            end if;
         end;
      end loop;
      return Table;
   end Load_Names;

   function Name_Count (Table : Name_Table) return Natural is
     (Natural (Table.Names.Length));

   ---------------------------------------------------------------------
   --  describe_commit
   ---------------------------------------------------------------------

   --  git's find_unique_abbrev: at least Abbrev digits (7 for the auto
   --  width, never fewer than 4), more when needed to be unique.
   function Unique_Abbrev
     (Repo   : Version.Repository.Repository_Handle;
      Id     : Object_Id_Storage;
      Abbrev : Integer) return String
   is
      Hex : constant String := To_String (Id);
      Min : constant Positive :=
        (if Abbrev < 0 then 7
         else Integer'Min (Integer'Max (Abbrev, 4), Hex'Length));
      N   : constant Natural :=
        Natural'Min (Hex'Length,
                     Version.Revisions.Unique_Abbrev_Length (Repo, Id, Min));
   begin
      --  A zero width (a misnamed tag still gets its suffix) is the whole id.
      if Abbrev = 0 then
         return Hex;
      end if;
      return Hex (Hex'First .. Hex'First + N - 1);
   end Unique_Abbrev;

   function Describe_Commit
     (Repo     : Version.Repository.Repository_Handle;
      Table    : in out Name_Table;
      Commit   : Version.Objects.Hex_Object_Id;
      Options  : Describe_Options;
      Messages : in out Unbounded_String) return String
   is
      subtype U32 is Interfaces.Unsigned_32;
      Seen_Flag : constant U32 := 1;

      Objects : Version.Object_Cache.Object_Cache;
      Names   : Name_Maps.Map renames Table.Names;

      package Flag_Maps is new Ada.Containers.Ordered_Maps
        (Key_Type => Object_Id_Storage, Element_Type => U32,
         "<"      => Version.Objects."<");
      Flags : Flag_Maps.Map;

      function Flags_Of (Id : Object_Id_Storage) return U32 is
         C : constant Flag_Maps.Cursor := Flags.Find (Id);
      begin
         return (if Flag_Maps.Has_Element (C) then Flag_Maps.Element (C) else 0);
      end Flags_Of;

      procedure Set_Flags (Id : Object_Id_Storage; F : U32) is
      begin
         Flags.Include (Id, F);
      end Set_Flags;

      --  The commit-date priority queue (newest first, first in first out
      --  among equal dates).
      type Queue_Item is record
         Id   : Object_Id_Storage;
         Date : Long_Long_Integer;
         Ctr  : Natural;
      end record;
      function Before (L, R : Queue_Item) return Boolean is
        (if L.Date /= R.Date then L.Date > R.Date else L.Ctr < R.Ctr);
      package Queues is new Ada.Containers.Ordered_Sets
        (Element_Type => Queue_Item, "<" => Before);
      Queue : Queues.Set;
      Ctr   : Natural := 0;

      function Commit_Date (Id : Object_Id_Storage) return Long_Long_Integer is
        (Commit_Committer_Time
           (Version.Object_Cache.Read_Object (Repo, Objects, Id)));

      procedure Put (Id : Object_Id_Storage) is
         Date : constant Long_Long_Integer := Commit_Date (Id);
      begin
         Queue.Insert (Queue_Item'(Id => Id, Date => Date, Ctr => Ctr));
         Ctr := Ctr + 1;
      end Put;

      function Get return Object_Id_Storage is
         Item : constant Queue_Item := Queue.First_Element;
      begin
         Queue.Delete_First;
         return Item.Id;
      end Get;

      function Parents_Of (Id : Object_Id_Storage) return Object_Id_Vectors.Vector
      is (Commit_Parent_Ids (Version.Object_Cache.Read_Object (Repo, Objects, Id)));

      type Possible_Tag is record
         Peeled      : Object_Id_Storage;   --  key into Names
         Depth       : Natural := 0;
         Found_Order : Natural := 0;
         Flag_Within : U32 := 0;
      end record;
      package Tag_Vectors is new Ada.Containers.Vectors
        (Index_Type => Positive, Element_Type => Possible_Tag);
      Matches : Tag_Vectors.Vector;

      Annotated_Cnt   : Natural := 0;
      Unannotated_Cnt : Natural := 0;
      Seen_Commits    : Natural := 0;
      Gave_Up_On      : Object_Id_Storage;
      Gave_Up         : Boolean := False;
      Result          : Unbounded_String;

      --  append_name
      procedure Append_Name (Peeled : Object_Id_Storage) is
         N : Commit_Name := Names (Peeled);
      begin
         if N.Prio = 2 and then not N.Name_Checked then
            declare
               Path  : constant String := To_String (N.Path);
               Short : constant String :=
                 (if Options.All_Refs then Path (Path'First + 5 .. Path'Last)
                  else Path);
            begin
               if To_String (N.Tag_Name) /= Short then
                  Append (Messages,
                          "warning: tag '" & Path & "' is externally known as '"
                          & To_String (N.Tag_Name) & "'" & LF);
                  N.Misnamed := True;
               end if;
            end;
            N.Name_Checked := True;
            Names.Replace (Peeled, N);
         end if;
         if N.Prio = 2 then
            if Options.All_Refs then
               Append (Result, "tags/");
            end if;
            Append (Result, N.Tag_Name);
         else
            Append (Result, N.Path);
         end if;
      end Append_Name;

      procedure Append_Suffix (Depth : Natural; Id : Object_Id_Storage) is
      begin
         Append (Result, "-" & Img (Depth) & "-g"
                 & Unique_Abbrev (Repo, Id, Options.Abbrev));
      end Append_Suffix;

      --  finish_depth_computation
      procedure Finish_Depth (Best : in out Possible_Tag) is
         package Id_Sets is new Ada.Containers.Ordered_Sets
           (Element_Type => Object_Id_Storage, "<" => Version.Objects."<");
         Unflagged : Id_Sets.Set;
      begin
         for Item of Queue loop
            if (Flags_Of (Item.Id) and Best.Flag_Within) = 0 then
               Unflagged.Include (Item.Id);
            end if;
         end loop;
         while not Queue.Is_Empty loop
            declare
               C  : constant Object_Id_Storage := Get;
               CF : constant U32 := Flags_Of (C);
            begin
               Seen_Commits := Seen_Commits + 1;
               if (CF and Best.Flag_Within) /= 0 then
                  exit when Unflagged.Is_Empty;
               else
                  Unflagged.Exclude (C);
                  Best.Depth := Best.Depth + 1;
               end if;
               for P of Parents_Of (C) loop
                  declare
                     PF       : constant U32 := Flags_Of (P);
                     Seen     : constant Boolean := (PF and Seen_Flag) /= 0;
                     Before_F : constant Boolean :=
                       (PF and Best.Flag_Within) /= 0;
                     After    : constant U32 := PF or CF;
                     After_F  : constant Boolean :=
                       (After and Best.Flag_Within) /= 0;
                  begin
                     if not Seen then
                        Put (P);
                     end if;
                     Set_Flags (P, After);
                     if not Seen and then not After_F then
                        Unflagged.Include (P);
                     end if;
                     if Seen and then not Before_F and then After_F then
                        Unflagged.Exclude (P);
                     end if;
                  end;
               end loop;
            end;
         end loop;
      end Finish_Depth;

      Max_Cand : constant Natural :=
        Natural'Min (Options.Candidates, Max_Candidates);
   begin
      --  Exact match to an existing ref.
      if Names.Contains (Commit) then
         declare
            N : constant Commit_Name := Names (Commit);
         begin
            if Options.Tags or else Options.All_Refs or else N.Prio = 2 then
               Append_Name (Commit);
               if Names (Commit).Misnamed or else Options.Long then
                  Append_Suffix (0, Commit);
               end if;
               Append (Result, Options.Suffix);
               return To_String (Result);
            end if;
         end;
      end if;

      if Max_Cand = 0 then
         raise Describe_Error with
           "no tag exactly matches '" & To_String (Commit) & "'";
      end if;
      if Options.Debug then
         Append
           (Messages, "No exact match on refs or tags, searching to describe" & LF);
      end if;

      Set_Flags (Commit, Seen_Flag);
      Put (Commit);
      while not Queue.Is_Empty loop
         declare
            C  : constant Object_Id_Storage := Get;
            CF : U32 := Flags_Of (C);
         begin
            Seen_Commits := Seen_Commits + 1;

            if Natural (Matches.Length) = Max_Cand
              or else Natural (Matches.Length) = Natural (Names.Length)
            then
               Gave_Up_On := C;
               Gave_Up := True;
               exit;
            end if;

            if Names.Contains (C) then
               declare
                  N : constant Commit_Name := Names (C);
               begin
                  if not Options.Tags and then not Options.All_Refs
                    and then N.Prio < 2
                  then
                     Unannotated_Cnt := Unannotated_Cnt + 1;
                  elsif Natural (Matches.Length) < Max_Cand then
                     declare
                        T : Possible_Tag;
                     begin
                        T.Peeled := C;
                        T.Depth := Seen_Commits - 1;
                        T.Found_Order := Natural (Matches.Length) + 1;
                        T.Flag_Within := Interfaces.Shift_Left (1, T.Found_Order);
                        Matches.Append (T);
                        CF := CF or T.Flag_Within;
                        Set_Flags (C, CF);
                        if N.Prio = 2 then
                           Annotated_Cnt := Annotated_Cnt + 1;
                        end if;
                     end;
                  end if;
               end;
            end if;

            for T of Matches loop
               if (CF and T.Flag_Within) = 0 then
                  T.Depth := T.Depth + 1;
               end if;
            end loop;

            --  Stop if the last remaining path is already covered by the
            --  best candidate(s).
            if Annotated_Cnt > 0 and then Queue.Is_Empty then
               declare
                  Best_Depth  : Natural := Natural'Last;
                  Best_Within : U32 := 0;
               begin
                  for T of Matches loop
                     if T.Depth < Best_Depth then
                        Best_Depth := T.Depth;
                        Best_Within := T.Flag_Within;
                     elsif T.Depth = Best_Depth then
                        Best_Within := Best_Within or T.Flag_Within;
                     end if;
                  end loop;
                  if (CF and Best_Within) = Best_Within then
                     if Options.Debug then
                        Append (Messages,
                                "finished search at " & To_String (C) & LF);
                     end if;
                     exit;
                  end if;
               end;
            end if;

            for P of Parents_Of (C) loop
               declare
                  PF : constant U32 := Flags_Of (P);
               begin
                  if (PF and Seen_Flag) = 0 then
                     Put (P);
                  end if;
                  Set_Flags (P, PF or CF);
               end;
               exit when Options.First_Parent;
            end loop;
         end;
      end loop;

      if Matches.Is_Empty then
         if Options.Always then
            Append (Result, Unique_Abbrev (Repo, Commit, Options.Abbrev));
            Append (Result, Options.Suffix);
            return To_String (Result);
         end if;
         if Unannotated_Cnt > 0 then
            raise Describe_Error with
              "No annotated tags can describe '" & To_String (Commit) & "'." & LF
              & "However, there were unannotated tags: try --tags.";
         else
            raise Describe_Error with
              "No tags can describe '" & To_String (Commit) & "'." & LF
              & "Try --always, or create some tags.";
         end if;
      end if;

      --  Sort by depth, then by the order found (a stable insertion sort).
      for I in 2 .. Natural (Matches.Length) loop
         declare
            V : constant Possible_Tag := Matches (I);
            J : Natural := I;
         begin
            while J > 1
              and then (Matches (J - 1).Depth > V.Depth
                        or else (Matches (J - 1).Depth = V.Depth
                                 and then Matches (J - 1).Found_Order
                                          > V.Found_Order))
            loop
               declare
                  Prev : constant Possible_Tag := Matches (J - 1);
               begin
                  Matches.Replace_Element (J, Prev);
               end;
               J := J - 1;
            end loop;
            Matches.Replace_Element (J, V);
         end;
      end loop;

      if Gave_Up then
         Put (Gave_Up_On);
         Seen_Commits := Seen_Commits - 1;
      end if;
      declare
         Best : Possible_Tag := Matches.First_Element;
      begin
         Finish_Depth (Best);
         Matches.Replace_Element (1, Best);
      end;

      if Options.Debug then
         for T of Matches loop
            declare
               N     : constant Commit_Name := Names (T.Peeled);
               Label : constant String :=
                 (case N.Prio is
                     when 2 => "annotated",
                     when 1 => "lightweight",
                     when others => "head");
               Depth : constant String := Img (T.Depth);
            begin
               Append (Messages,
                       " " & Label & [1 .. 11 - Label'Length => ' ']
                       & " " & [1 .. Integer'Max (0, 8 - Depth'Length) => ' ']
                       & Depth & " " & To_String (N.Path) & LF);
            end;
         end loop;
         Append (Messages, "traversed " & Img (Seen_Commits) & " commits" & LF);
         if Gave_Up then
            Append (Messages,
                    "found " & Img (Max_Cand) & " tags; gave up search at "
                    & To_String (Gave_Up_On) & LF);
         end if;
      end if;

      Append_Name (Matches.First_Element.Peeled);
      if Names (Matches.First_Element.Peeled).Misnamed
        or else Options.Abbrev /= 0
      then
         Append_Suffix (Matches.First_Element.Depth, Commit);
      end if;
      Append (Result, Options.Suffix);
      return To_String (Result);
   end Describe_Commit;

   ---------------------------------------------------------------------
   --  describe_blob
   ---------------------------------------------------------------------

   function Describe_Blob
     (Repo     : Version.Repository.Repository_Handle;
      Table    : in out Name_Table;
      Blob     : Version.Objects.Hex_Object_Id;
      Options  : Describe_Options;
      Messages : in out Unbounded_String) return String
   is
      Head    : constant String := Version.Refs.Current_Commit_Id (Repo);
      Objects : Version.Object_Cache.Object_Cache;
      Trees   : Version.Tree_Cache.Tree_Cache;
      Tips    : Version.History.Commit_Id_Vectors.Vector;
      package Id_Sets is new Ada.Containers.Ordered_Sets
        (Element_Type => Object_Id_Storage, "<" => Version.Objects."<");
      Seen    : Id_Sets.Set;
   begin
      if Head = "" then
         raise Describe_Error with
           "cannot search for blob '" & To_String (Blob) & "' on an unborn branch";
      end if;
      Tips.Append (To_Object_Id (Head));
      declare
         Listed : constant Version.History.Commit_Id_Vectors.Vector :=
           Version.History.Rev_List (Repo, Tips);
      begin
         --  Oldest first (--reverse), each object reported at the first
         --  commit that has it (--objects).
         for I in reverse Listed.First_Index .. Listed.Last_Index loop
            declare
               C    : constant Object_Id_Storage := Listed (I);
               Tree : constant Object_Id_Storage :=
                 Commit_Tree_Id
                   (Version.Object_Cache.Read_Object (Repo, Objects, C));
            begin
               if not Seen.Contains (Tree) then
                  Seen.Include (Tree);
                  declare
                     Flat : constant Tree_Entry_Vectors.Vector :=
                       Version.Tree_Cache.Flatten_Tree (Repo, Trees, Tree);
                  begin
                     for E of Flat loop
                        if E.Kind = Tree_Blob and then not Seen.Contains (E.Id)
                        then
                           Seen.Include (E.Id);
                           if E.Id = Blob then
                              return Describe_Commit
                                       (Repo, Table, C, Options, Messages)
                                & ":" & To_String (E.Path);
                           end if;
                        end if;
                     end loop;
                  end;
               end if;
            end;
         end loop;
      end;
      raise Describe_Error with
        "blob '" & To_String (Blob) & "' not reachable from HEAD";
   end Describe_Blob;

   ---------------------------------------------------------------------
   --  The older entry points
   ---------------------------------------------------------------------

   function Describe_With
     (Repo    : Version.Repository.Repository_Handle;
      Commit  : Version.Objects.Hex_Object_Id;
      Options : Describe_Options) return String
   is
      Table    : Name_Table := Load_Names (Repo, Options);
      Messages : Unbounded_String;
   begin
      if Name_Count (Table) = 0 then
         raise Ada.IO_Exceptions.Data_Error with
           "No names found, cannot describe anything.";
      end if;
      return Describe_Commit (Repo, Table, Commit, Options, Messages);
   exception
      when E : Describe_Error =>
         raise Ada.IO_Exceptions.Data_Error with
           Ada.Exceptions.Exception_Message (E);
   end Describe_With;

   function Describe
     (Repo     : Version.Repository.Repository_Handle;
      Commit   : Version.Objects.Hex_Object_Id;
      All_Tags : Boolean := False;
      Long     : Boolean := False;
      Abbrev   : Natural := 7;
      Pattern  : String  := "";
      Exclude  : String  := "")
      return String
   is
      Options : Describe_Options;
   begin
      Options.Tags := All_Tags;
      Options.Long := Long;
      Options.Abbrev := Abbrev;
      if Pattern /= "" then
         Options.Patterns.Append (Pattern);
      end if;
      if Exclude /= "" then
         Options.Excludes.Append (Exclude);
      end if;
      return Describe_With (Repo, Commit, Options);
   end Describe;

   function Describe_By_Any_Ref
     (Repo    : Version.Repository.Repository_Handle;
      Commit  : Version.Objects.Hex_Object_Id;
      Long    : Boolean := False;
      Abbrev  : Natural := 7;
      Pattern : String  := "";
      Exclude : String  := "")
      return String
   is
      Options : Describe_Options;
   begin
      Options.All_Refs := True;
      Options.Long := Long;
      Options.Abbrev := Abbrev;
      if Pattern /= "" then
         Options.Patterns.Append (Pattern);
      end if;
      if Exclude /= "" then
         Options.Excludes.Append (Exclude);
      end if;
      return Describe_With (Repo, Commit, Options);
   end Describe_By_Any_Ref;

end Version.Describe;
