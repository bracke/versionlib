with Ada.Characters.Handling;
with Ada.Containers.Indefinite_Ordered_Sets;
with Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with GNAT.Regpat;

with Version.Objects; use Version.Objects;
with Version.Object_Cache;
with Version.Pack_Index_Cache;
with Version.Ref_Cache;
with Version.Files;
with Version.Reflog;
with Version.Staging;
with Version.Ref_Format;

package body Version.Revisions is

   function Join (Left, Right : String) return String renames Version.Files.Join;

   function Is_Hex_Digit (C : Character) return Boolean is
   begin
      return
        (C >= '0' and then C <= '9')
        or else (C >= 'a' and then C <= 'f')
        or else (C >= 'A' and then C <= 'F');
   end Is_Hex_Digit;

   function Is_Hex_Text (Text : String) return Boolean is
   begin
      if Text'Length = 0 then
         return False;
      end if;

      for C of Text loop
         if not Is_Hex_Digit (C) then
            return False;
         end if;
      end loop;

      return True;
   end Is_Hex_Text;

   function Lower (Text : String) return String is
      Result : String (Text'Range);
   begin
      for I in Text'Range loop
         Result (I) := Ada.Characters.Handling.To_Lower (Text (I));
      end loop;

      return Result;
   end Lower;

   function Has_Prefix (Text, Prefix : String) return Boolean is
   begin
      return Text'Length >= Prefix'Length
        and then Text (Text'First .. Text'First + Prefix'Length - 1) = Prefix;
   end Has_Prefix;

   function Unique_Abbrev_Length
     (Repo    : Version.Repository.Repository_Handle;
      Id      : Version.Objects.Hex_Object_Id;
      Minimum : Positive)
      return Natural
   is
      Full : constant String := Lower (To_String (Id));
      Min  : constant Positive :=
        (if Minimum > Full'Length then Full'Length else Minimum);
      Fanout : constant String := Full (Full'First .. Full'First + 1);
      Objects_Dir : constant String :=
        Join (Version.Repository.Common_Git_Dir (Repo), "objects");
      Sub : constant String := Join (Objects_Dir, Fanout);

      package Id_Sets is new Ada.Containers.Indefinite_Ordered_Sets (String);
      Loose : Id_Sets.Set;
      Packs : Version.Pack_Index_Cache.Cache;

      use type Ada.Directories.File_Kind;
   begin
      --  Collect loose object ids sharing the two-char fanout directory; only
      --  those can collide with Full on a prefix of length >= 2.
      if Ada.Directories.Exists (Sub)
        and then Ada.Directories.Kind (Sub) = Ada.Directories.Directory
      then
         declare
            S : Ada.Directories.Search_Type;
            E : Ada.Directories.Directory_Entry_Type;
         begin
            Ada.Directories.Start_Search
              (S, Sub, "*",
               [Ada.Directories.Ordinary_File => True, others => False]);
            while Ada.Directories.More_Entries (S) loop
               Ada.Directories.Get_Next_Entry (S, E);
               declare
                  Name : constant String := Ada.Directories.Simple_Name (E);
               begin
                  if Name'Length = Full'Length - 2
                    and then Is_Hex_Text (Name)
                  then
                     Loose.Include (Lower (Fanout & Name));
                  end if;
               end;
            end loop;
            Ada.Directories.End_Search (S);
         end;
      end if;

      Version.Pack_Index_Cache.Load (Repo => Repo, Item => Packs);

      for L in Min .. Full'Length loop
         declare
            Prefix : constant String :=
              Full (Full'First .. Full'First + L - 1);
            Count  : Natural := 0;
            Match  : Version.Objects.Object_Id_Storage :=
              Version.Objects.Zero_Object_Id;
         begin
            for O of Loose loop
               if Has_Prefix (O, Prefix) then
                  Count := Count + 1;
               end if;
            end loop;
            Version.Pack_Index_Cache.Match_Prefix
              (Item => Packs, Prefix => Prefix, Count => Count, Match => Match);
            if Count <= 1 then
               return L;
            end if;
         end;
      end loop;
      return Full'Length;
   exception
      when others =>
         return Min;
   end Unique_Abbrev_Length;

   function Resolve_Ref_Name
     (Repo  : Version.Repository.Repository_Handle;
      Refs  : in out Version.Ref_Cache.Ref_Cache;
      Name  : String;
      Id    : out Version.Objects.Hex_Object_Id)
      return Boolean
   is
   begin
      return Version.Ref_Cache.Try_Resolve_Ref
        (Repo  => Repo,
         Cache => Refs,
         Name  => Name,
         Id    => Id);
   end Resolve_Ref_Name;

   procedure Consider_Loose_Object
     (Candidate : Version.Objects.Hex_Object_Id;
      Prefix    : String;
      Count     : in out Natural;
      Match     : in out Version.Objects.Hex_Object_Id)
   is
      Candidate_Text : constant String := Lower (To_String (Candidate));
      Prefix_Text    : constant String := Lower (Prefix);
   begin
      if Candidate_Text'Length >= Prefix_Text'Length
        and then Candidate_Text
          (Candidate_Text'First .. Candidate_Text'First + Prefix_Text'Length - 1)
          = Prefix_Text
      then
         Count := Count + 1;
         Match := Candidate;
      end if;
   end Consider_Loose_Object;

   function Resolve_Abbreviation
     (Repo   : Version.Repository.Repository_Handle;
      Packs  : in out Version.Pack_Index_Cache.Cache;
      Prefix : String)
      return Version.Objects.Hex_Object_Id
   is
      Objects_Dir : constant String :=
        Join (Version.Repository.Common_Git_Dir (Repo), "objects");
      Search      : Ada.Directories.Search_Type;
      Dir_Entry   : Ada.Directories.Directory_Entry_Type;
      File_Search : Ada.Directories.Search_Type;
      File_Entry  : Ada.Directories.Directory_Entry_Type;
      Count       : Natural := 0;
      Match       : Version.Objects.Object_Id_Storage := Version.Objects.Zero_Object_Id;
      Search_Open : Boolean := False;
      Files_Open  : Boolean := False;
   begin
      if Prefix'Length < 4 or else not Is_Hex_Text (Prefix) then
         raise Ada.IO_Exceptions.Data_Error with "unknown revision: " & Prefix;
      end if;

      if not Ada.Directories.Exists (Objects_Dir) then
         raise Ada.IO_Exceptions.Data_Error with "unknown revision: " & Prefix;
      end if;

      Ada.Directories.Start_Search
        (Search    => Search,
         Directory => Objects_Dir,
         Pattern   => "*",
         Filter    => [Ada.Directories.Directory => True,
                       others => False]);
      Search_Open := True;

      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Dir_Entry);

         declare
            Dir_Name : constant String :=
              Ada.Directories.Simple_Name (Dir_Entry);
            Dir_Path : constant String :=
              Ada.Directories.Full_Name (Dir_Entry);
         begin
            if Dir_Name'Length = 2 and then Is_Hex_Text (Dir_Name) then
               Ada.Directories.Start_Search
                 (Search    => File_Search,
                  Directory => Dir_Path,
                  Pattern   => "*",
                  Filter    => [Ada.Directories.Ordinary_File => True,
                                others => False]);
               Files_Open := True;

               while Ada.Directories.More_Entries (File_Search) loop
                  Ada.Directories.Get_Next_Entry (File_Search, File_Entry);

                  declare
                     File_Name : constant String :=
                       Ada.Directories.Simple_Name (File_Entry);
                  begin
                     if File_Name'Length = 38 and then Is_Hex_Text (File_Name) then
                        declare
                           Candidate : constant Version.Objects.Hex_Object_Id :=
                             Version.Objects.To_Object_Id (Lower (Dir_Name & File_Name));
                        begin
                           Consider_Loose_Object
                             (Candidate => Candidate,
                              Prefix    => Prefix,
                              Count     => Count,
                              Match     => Match);
                        end;
                     end if;
                  end;
               end loop;

               Ada.Directories.End_Search (File_Search);
               Files_Open := False;
            end if;
         end;
      end loop;

      Ada.Directories.End_Search (Search);
      Search_Open := False;

      Version.Pack_Index_Cache.Load (Repo => Repo, Item => Packs);
      Version.Pack_Index_Cache.Match_Prefix
        (Item   => Packs,
         Prefix => Prefix,
         Count  => Count,
         Match  => Match);

      if Count = 0 then
         raise Ada.IO_Exceptions.Data_Error with "unknown revision: " & Prefix;
      elsif Count > 1 then
         raise Ada.IO_Exceptions.Data_Error with "ambiguous revision: " & Prefix;
      else
         return Match;
      end if;

   exception
      when others =>
         if Files_Open then
            Ada.Directories.End_Search (File_Search);
            Files_Open := False;
         end if;

         if Search_Open then
            Ada.Directories.End_Search (Search);
            Search_Open := False;
         end if;

         raise;
   end Resolve_Abbreviation;

   function Resolve_Base
     (Repo  : Version.Repository.Repository_Handle;
      Refs  : in out Version.Ref_Cache.Ref_Cache;
      Packs : in out Version.Pack_Index_Cache.Cache;
      Name  : String)
      return Version.Objects.Hex_Object_Id
   is
      Id : Version.Objects.Object_Id_Storage := Version.Objects.Zero_Object_Id;
   begin
      if Name'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with "empty revision";
      end if;

      if Name = "HEAD" then
         declare
            Head_Id : constant String := Version.Ref_Cache.Current_Commit_Id (Repo => Repo, Cache => Refs);
         begin
            if not Version.Objects.Is_Valid_Hex_Object_Id (Head_Id) then
               raise Ada.IO_Exceptions.Data_Error with
                 "HEAD does not point to a commit";
            end if;

            return Version.Objects.To_Object_Id (Head_Id);
         end;
      end if;

      if (Name'Length = 40 or else Name'Length = 64) and then Is_Hex_Text (Name) then
         return Version.Objects.To_Object_Id (Lower (Name));
      end if;

      if not Has_Prefix (Name, "refs/") then
         if Resolve_Ref_Name (Repo, Refs, "refs/heads/" & Name, Id) then
            return Id;
         end if;

         if Resolve_Ref_Name (Repo, Refs, "refs/tags/" & Name, Id) then
            return Id;
         end if;

         if Resolve_Ref_Name (Repo, Refs, "refs/remotes/" & Name, Id) then
            return Id;
         end if;
      end if;

      if Has_Prefix (Name, "refs/") then
         if Resolve_Ref_Name (Repo, Refs, Name, Id) then
            return Id;
         end if;
      end if;

      if Name'Length >= 4 and then Is_Hex_Text (Name) then
         return Resolve_Abbreviation (Repo, Packs, Name);
      end if;

      raise Ada.IO_Exceptions.Data_Error with "unknown revision: " & Name;
   end Resolve_Base;

   function Parent_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Objects   : in out Version.Object_Cache.Object_Cache;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Index     : Positive)
      return Version.Objects.Hex_Object_Id
   is
      Obj     : constant Version.Objects.Git_Object :=
        Version.Object_Cache.Read_Object (Repo, Objects, Commit_Id);
      Parents : constant Version.Objects.Object_Id_Vectors.Vector :=
        Version.Objects.Commit_Parent_Ids (Obj);
   begin
      if Version.Objects.Kind (Obj) /= Version.Objects.Commit_Object then
         raise Ada.IO_Exceptions.Data_Error with "object is not a commit: " & To_String (Commit_Id);
      end if;

      if Natural (Parents.Length) < Index then
         raise Ada.IO_Exceptions.Data_Error with "parent does not exist";
      end if;

      return Parents.Element (Parents.First_Index + Index - 1);
   end Parent_Commit;

   function Peel_Tag_Object_Id
     (Repo    : Version.Repository.Repository_Handle;
      Objects : in out Version.Object_Cache.Object_Cache;
      Id      : Version.Objects.Hex_Object_Id)
      return Version.Objects.Hex_Object_Id
   is
      Current : Version.Objects.Hex_Object_Id := Id;
   begin
      for Depth in 1 .. 100 loop
         declare
            Obj : constant Version.Objects.Git_Object :=
              Version.Object_Cache.Read_Object (Repo, Objects, Current);
         begin
            if Version.Objects.Kind (Obj) /= Version.Objects.Tag_Object then
               return Current;
            end if;

            Current := Version.Objects.Tag_Target_Id (Obj);
         end;
      end loop;

      raise Ada.IO_Exceptions.Data_Error with "tag reference chain too deep";
   end Peel_Tag_Object_Id;

   function Require_Commit
     (Repo    : Version.Repository.Repository_Handle;
      Objects : in out Version.Object_Cache.Object_Cache;
      Id      : Version.Objects.Hex_Object_Id)
      return Version.Objects.Hex_Object_Id
   is
      Peeled : constant Version.Objects.Hex_Object_Id :=
        Peel_Tag_Object_Id (Repo, Objects, Id);
      Obj : constant Version.Objects.Git_Object :=
        Version.Object_Cache.Read_Object (Repo, Objects, Peeled);
   begin
      if Version.Objects.Kind (Obj) /= Version.Objects.Commit_Object then
         raise Ada.IO_Exceptions.Data_Error with "object is not a commit: " & To_String (Id);
      end if;

      return Peeled;
   end Require_Commit;

   function To_Tree
     (Repo    : Version.Repository.Repository_Handle;
      Objects : in out Version.Object_Cache.Object_Cache;
      Id      : Version.Objects.Hex_Object_Id)
      return Version.Objects.Hex_Object_Id
   is
      Peeled : constant Version.Objects.Hex_Object_Id :=
        Peel_Tag_Object_Id (Repo, Objects, Id);
      Obj : constant Version.Objects.Git_Object :=
        Version.Object_Cache.Read_Object (Repo, Objects, Peeled);
   begin
      case Version.Objects.Kind (Obj) is
         when Version.Objects.Tree_Object =>
            return Peeled;

         when Version.Objects.Commit_Object =>
            return Version.Objects.Commit_Tree_Id (Obj);

         when others =>
            raise Ada.IO_Exceptions.Data_Error with "object is not treeish: " & To_String (Id);
      end case;
   end To_Tree;

   function Apply_Brace_Suffix
     (Repo    : Version.Repository.Repository_Handle;
      Objects : in out Version.Object_Cache.Object_Cache;
      Id      : Version.Objects.Hex_Object_Id;
      Suffix  : String)
      return Version.Objects.Hex_Object_Id
   is
   begin
      if Suffix = "commit" then
         return Require_Commit (Repo, Objects, Id);
      elsif Suffix = "tree" then
         return To_Tree (Repo, Objects, Id);
      elsif Suffix = "" then
         return Peel_Tag_Object_Id (Repo, Objects, Id);
      else
         raise Ada.IO_Exceptions.Data_Error with "invalid revision suffix: ^{" & Suffix & "}";
      end if;
   end Apply_Brace_Suffix;

   --  Walk a slash-separated Path from Root_Tree, returning the object id of
   --  the named entry (blob, subtree, or gitlink). Empty components (leading,
   --  trailing, or doubled slashes) are skipped; an empty path returns the
   --  root tree itself. Used for git's `<rev>:<path>` syntax.
   function Navigate_Tree_Path
     (Repo      : Version.Repository.Repository_Handle;
      Root_Tree : Version.Objects.Hex_Object_Id;
      Path      : String)
      return Version.Objects.Hex_Object_Id
   is
      Current : Version.Objects.Hex_Object_Id := Root_Tree;
      Start   : Natural := Path'First;
   begin
      while Start <= Path'Last loop
         declare
            Stop : Natural := Start;
         begin
            while Stop <= Path'Last and then Path (Stop) /= '/' loop
               Stop := Stop + 1;
            end loop;

            if Stop > Start then   --  skip empty components
               declare
                  Comp    : constant String := Path (Start .. Stop - 1);
                  Is_Last : constant Boolean := Stop > Path'Last;
                  Found   : Boolean := False;
                  Ent_Id  : Version.Objects.Hex_Object_Id :=
                    Version.Objects.Zero_Object_Id;
                  Ent_Kind : Version.Objects.Tree_Entry_Kind :=
                    Version.Objects.Tree_Blob;
               begin
                  for E of Version.Objects.Tree_Entries (Repo, Current) loop
                     if Ada.Strings.Unbounded.To_String (E.Path) = Comp then
                        Found := True;
                        Ent_Id := E.Id;
                        Ent_Kind := E.Kind;
                        exit;
                     end if;
                  end loop;

                  if not Found then
                     raise Ada.IO_Exceptions.Data_Error with
                       "path not in tree: " & Path;
                  end if;

                  if Is_Last then
                     return Ent_Id;
                  end if;

                  if Ent_Kind /= Version.Objects.Tree_Directory then
                     raise Ada.IO_Exceptions.Data_Error with
                       "not a tree on path: " & Comp;
                  end if;

                  Current := Ent_Id;
               end;
            end if;

            Start := Stop + 1;
         end;
      end loop;

      return Current;   --  empty / trailing-slash path: the tree itself
   end Navigate_Tree_Path;

   function Decimal_Value (Text : String) return Natural is
      Value : Natural := 0;
   begin
      if Text'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with "invalid revision suffix";
      end if;

      for C of Text loop
         if C < '0' or else C > '9' then
            raise Ada.IO_Exceptions.Data_Error with "invalid revision suffix";
         end if;

         Value := Value * 10 + (Character'Pos (C) - Character'Pos ('0'));
      end loop;

      return Value;
   end Decimal_Value;

   LF : constant Character := Character'Val (10);

   --  The committer unix timestamp of a commit (0 if unparseable).
   function Committer_Time (Content : String) return Long_Long_Integer is
      Start : constant Natural :=
        Ada.Strings.Fixed.Index (Content, LF & "committer ");
   begin
      if Start = 0 then
         return 0;
      end if;
      declare
         Line_Start : constant Natural := Start + 1;
         LEnd       : Natural := Line_Start;
      begin
         while LEnd <= Content'Last and then Content (LEnd) /= LF loop
            LEnd := LEnd + 1;
         end loop;
         declare
            Line    : constant String := Content (Line_Start .. LEnd - 1);
            Last_Sp : Natural := 0;
            Prev_Sp : Natural := 0;
         begin
            for I in reverse Line'Range loop
               if Line (I) = ' ' then
                  if Last_Sp = 0 then
                     Last_Sp := I;
                  else
                     Prev_Sp := I;
                     exit;
                  end if;
               end if;
            end loop;
            if Prev_Sp = 0 or else Last_Sp = 0 then
               return 0;
            end if;
            return Long_Long_Integer'Value (Line (Prev_Sp + 1 .. Last_Sp - 1));
         end;
      end;
   exception
      when others =>
         return 0;
   end Committer_Time;

   --  A commit's log message (everything after the header/body separator).
   function Commit_Message (Content : String) return String is
      Sep : constant Natural := Ada.Strings.Fixed.Index (Content, LF & LF);
   begin
      if Sep = 0 then
         return "";
      end if;
      return Content (Sep + 2 .. Content'Last);
   end Commit_Message;

   package Str_Sets is new Ada.Containers.Indefinite_Ordered_Sets (String);

   --  `:/<regex>` — the youngest commit reachable from any ref (and HEAD)
   --  whose log message matches the regular expression.
   function Resolve_Message_Search
     (Repo    : Version.Repository.Repository_Handle;
      Objects : in out Version.Object_Cache.Object_Cache;
      Pattern : String)
      return Version.Objects.Hex_Object_Id
   is
      use type GNAT.Regpat.Match_Location;
      Visited : Str_Sets.Set;
      Queue   : Version.Objects.Object_Id_Vectors.Vector;
      Best_Id : Version.Objects.Object_Id_Storage :=
        Version.Objects.Zero_Object_Id;
      Best_Ts : Long_Long_Integer := Long_Long_Integer'First;
      Have    : Boolean := False;
      Refs    : Version.Ref_Cache.Ref_Cache;
      No_Pats : Version.Ref_Format.String_Vectors.Vector;
   begin
      if Pattern'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with "empty search pattern";
      end if;

      declare
         Matcher : constant GNAT.Regpat.Pattern_Matcher :=
           GNAT.Regpat.Compile (Pattern);

         procedure Seed (Id_Text : String) is
         begin
            if Version.Objects.Is_Valid_Hex_Object_Id (Id_Text) then
               Queue.Append
                 (Require_Commit
                    (Repo, Objects, Version.Objects.To_Object_Id (Id_Text)));
            end if;
         exception
            when Ada.IO_Exceptions.Data_Error =>
               null;   --  a ref that does not peel to a commit
         end Seed;
      begin
         Seed (Version.Ref_Cache.Current_Commit_Id (Repo => Repo, Cache => Refs));
         for Line of Version.Ref_Format.For_Each_Ref
           (Repo, No_Pats, Format => "%(objectname)")
         loop
            Seed (Line);
         end loop;

         while not Queue.Is_Empty loop
            declare
               Id : constant Version.Objects.Object_Id_Storage :=
                 Queue.Last_Element;
            begin
               Queue.Delete_Last;
               if not Visited.Contains (Version.Objects.To_String (Id)) then
                  Visited.Insert (Version.Objects.To_String (Id));
                  declare
                     Obj : constant Version.Objects.Git_Object :=
                       Version.Object_Cache.Read_Object (Repo, Objects, Id);
                  begin
                     if Version.Objects.Kind (Obj)
                       = Version.Objects.Commit_Object
                     then
                        declare
                           C : constant String := Version.Objects.Content (Obj);
                           M : GNAT.Regpat.Match_Array (0 .. 0);
                        begin
                           GNAT.Regpat.Match (Matcher, Commit_Message (C), M);
                           if M (0) /= GNAT.Regpat.No_Match then
                              declare
                                 Ts : constant Long_Long_Integer :=
                                   Committer_Time (C);
                              begin
                                 if Ts > Best_Ts then
                                    Best_Ts := Ts;
                                    Best_Id := Id;
                                    Have := True;
                                 end if;
                              end;
                           end if;
                           for P of Version.Objects.Commit_Parent_Ids (Obj) loop
                              Queue.Append (P);
                           end loop;
                        end;
                     end if;
                  end;
               end if;
            end;
         end loop;
      end;

      if not Have then
         raise Ada.IO_Exceptions.Data_Error
           with "no commit message matches: " & Pattern;
      end if;
      return Best_Id;
   exception
      when GNAT.Regpat.Expression_Error =>
         raise Ada.IO_Exceptions.Data_Error
           with "invalid search pattern: " & Pattern;
   end Resolve_Message_Search;

   --  `:[<stage>:]<path>` — the blob recorded in the index at the given stage
   --  (default 0).
   function Resolve_Index_Blob
     (Repo : Version.Repository.Repository_Handle;
      Rest : String)
      return Version.Objects.Hex_Object_Id
   is
      Stage : Natural := 0;
      First : Natural := Rest'First;
   begin
      if Rest'Length >= 2
        and then Rest (Rest'First) in '0' .. '3'
        and then Rest (Rest'First + 1) = ':'
      then
         Stage := Character'Pos (Rest (Rest'First)) - Character'Pos ('0');
         First := Rest'First + 2;
      end if;

      declare
         Path    : constant String := Rest (First .. Rest'Last);
         Entries : constant Version.Staging.Index_Entry_Vectors.Vector :=
           Version.Staging.Load (Repo);
         Idx     : constant Natural :=
           Version.Staging.Find_Stage_Entry (Entries, Path, Stage);
      begin
         if Idx = Natural'Last then
            raise Ada.IO_Exceptions.Data_Error
              with "path '" & Path & "' is not in the index";
         end if;
         return Entries.Element (Idx).Id;
      end;
   end Resolve_Index_Blob;

   function Resolve
     (Repo : Version.Repository.Repository_Handle;
      Text : String;
      Kind : Revision_Kind := Any_Object)
      return Version.Objects.Hex_Object_Id
   is
      Rev        : constant String := Ada.Strings.Fixed.Trim (Text, Ada.Strings.Both);
      Base_Last  : Natural := Rev'First - 1;
      Pos        : Natural;
      Current    : Version.Objects.Object_Id_Storage := Version.Objects.Zero_Object_Id;
      Objects    : Version.Object_Cache.Object_Cache;
      Refs       : Version.Ref_Cache.Ref_Cache;
      Packs      : Version.Pack_Index_Cache.Cache;
   begin
      if Rev'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with "empty revision";
      end if;

      --  Reflog syntax: `<ref>@{<n>}` resolves to the value the ref held n
      --  reflog entries ago (@{0} is the current value; a bare `@{n}` is HEAD).
      declare
         At_Pos : Natural := 0;
      begin
         for I in Rev'First .. Rev'Last - 1 loop
            if Rev (I) = '@' and then Rev (I + 1) = '{' then
               At_Pos := I;
               exit;
            end if;
         end loop;

         if At_Pos > 0 and then Rev (Rev'Last) = '}' then
            declare
               Inner  : constant String := Rev (At_Pos + 2 .. Rev'Last - 1);
               Ref_In : constant String :=
                 (if At_Pos = Rev'First then "HEAD"
                  else Rev (Rev'First .. At_Pos - 1));
               Ref    : constant String :=
                 (if Ref_In = "HEAD" then "HEAD"
                  else "refs/heads/" & Ref_In);
               Is_Num : Boolean := Inner'Length > 0;
            begin
               for C of Inner loop
                  if C not in '0' .. '9' then
                     Is_Num := False;
                  end if;
               end loop;

               if Is_Num then
                  declare
                     Entries : constant Version.Reflog.Log_Entry_Vectors.Vector
                       := Version.Reflog.Read_Entries (Repo, Ref);
                     N : constant Natural := Natural'Value (Inner);
                  begin
                     if Entries.Is_Empty then
                        raise Ada.IO_Exceptions.Data_Error
                          with "no reflog for " & Ref;
                     end if;
                     --  git accepts @{n} for n in 0 .. entry-count-1.
                     if N >= Natural (Entries.Length) then
                        raise Ada.IO_Exceptions.Data_Error with
                          "log for " & Ref & " only has "
                          & Ada.Strings.Fixed.Trim
                              (Integer'Image (Integer (Entries.Length)),
                               Ada.Strings.Both) & " entries";
                     end if;
                     if N = 0 then
                        return Version.Objects.To_Object_Id
                          (Ada.Strings.Unbounded.To_String
                             (Entries.Last_Element.New_Id));
                     end if;
                     return Version.Objects.To_Object_Id
                       (Ada.Strings.Unbounded.To_String
                          (Entries.Element
                             (Entries.Last_Index - (N - 1)).Old_Id));
                  end;
               end if;
            end;
         end if;
      end;

      --  Colon syntax: `<rev>:<path>` resolves <rev> to a tree and looks up
      --  <path> within it; a leading ':' is index / `:/regex` search syntax
      --  (`:path`, `:<stage>:path`, `:/<regex>`).
      declare
         Colon : Natural := 0;
      begin
         for I in Rev'Range loop
            if Rev (I) = ':' then
               Colon := I;
               exit;
            end if;
         end loop;

         if Colon > Rev'First then
            declare
               Tree_Id : constant Version.Objects.Hex_Object_Id :=
                 Resolve (Repo, Rev (Rev'First .. Colon - 1), Treeish);
               Path    : constant String := Rev (Colon + 1 .. Rev'Last);
               Result  : constant Version.Objects.Hex_Object_Id :=
                 Navigate_Tree_Path (Repo, Tree_Id, Path);
            begin
               case Kind is
                  when Any_Object => return Result;
                  when Commitish  => return Require_Commit (Repo, Objects, Result);
                  when Treeish    => return To_Tree (Repo, Objects, Result);
               end case;
            end;
         elsif Colon = Rev'First then
            declare
               Rest   : constant String := Rev (Rev'First + 1 .. Rev'Last);
               Result : Version.Objects.Hex_Object_Id;
            begin
               if Rest'Length = 0 then
                  raise Ada.IO_Exceptions.Data_Error with "empty revision";
               end if;
               if Rest (Rest'First) = '/' then
                  Result := Resolve_Message_Search
                    (Repo, Objects, Rest (Rest'First + 1 .. Rest'Last));
               else
                  Result := Resolve_Index_Blob (Repo, Rest);
               end if;
               case Kind is
                  when Any_Object => return Result;
                  when Commitish  => return Require_Commit (Repo, Objects, Result);
                  when Treeish    => return To_Tree (Repo, Objects, Result);
               end case;
            end;
         end if;
      end;

      Pos := Rev'First;
      while Pos <= Rev'Last loop
         exit when Rev (Pos) = '^' or else Rev (Pos) = '~';
         Base_Last := Pos;
         Pos := Pos + 1;
      end loop;

      if Base_Last < Rev'First then
         raise Ada.IO_Exceptions.Data_Error with "empty revision";
      end if;

      Current := Resolve_Base (Repo, Refs, Packs, Rev (Rev'First .. Base_Last));

      while Pos <= Rev'Last loop
         if Rev (Pos) = '^' then
            if Pos < Rev'Last and then Rev (Pos + 1) = '{' then
               declare
                  Close : Natural := 0;
               begin
                  for I in Pos + 2 .. Rev'Last loop
                     if Rev (I) = '}' then
                        Close := I;
                        exit;
                     end if;
                  end loop;

                  if Close = 0 then
                     raise Ada.IO_Exceptions.Data_Error with "invalid revision suffix";
                  end if;

                  Current := Apply_Brace_Suffix
                    (Repo,
                     Objects,
                     Current,
                     Rev (Pos + 2 .. Close - 1));
                  Pos := Close + 1;
               end;
            elsif Pos = Rev'Last then
               Current := Parent_Commit (Repo, Objects, Current, 1);
               Pos := Pos + 1;
            elsif Rev (Pos + 1) in '0' .. '9' then
               declare
                  Start : constant Natural := Pos + 1;
                  Stop  : Natural := Start;
               begin
                  while Stop <= Rev'Last and then Rev (Stop) in '0' .. '9' loop
                     Stop := Stop + 1;
                  end loop;

                  declare
                     Parent_Index : constant Natural :=
                       Decimal_Value (Rev (Start .. Stop - 1));
                  begin
                     if Parent_Index = 0 then
                        raise Ada.IO_Exceptions.Data_Error with "invalid parent index";
                     end if;

                     Current := Parent_Commit (Repo, Objects, Current, Positive (Parent_Index));
                     Pos := Stop;
                  end;
               end;
            elsif Rev (Pos + 1) = '^' or else Rev (Pos + 1) = '~' then
               Current := Parent_Commit (Repo, Objects, Current, 1);
               Pos := Pos + 1;
            else
               raise Ada.IO_Exceptions.Data_Error with "invalid revision suffix";
            end if;

         elsif Rev (Pos) = '~' then
            declare
               Start : constant Natural := Pos + 1;
               Stop  : Natural := Start;
               Count : Natural;
            begin
               while Stop <= Rev'Last and then Rev (Stop) in '0' .. '9' loop
                  Stop := Stop + 1;
               end loop;

               Count :=
                 (if Stop = Start then 1 else Decimal_Value (Rev (Start .. Stop - 1)));

               for I in 1 .. Count loop
                  Current := Parent_Commit (Repo, Objects, Current, 1);
               end loop;

               Pos := Stop;
            end;
         else
            raise Ada.IO_Exceptions.Data_Error with "invalid revision suffix";
         end if;
      end loop;

      case Kind is
         when Any_Object =>
            declare
               Obj : constant Version.Objects.Git_Object :=
                 Version.Object_Cache.Read_Object (Repo, Objects, Current);
            begin
               if Version.Objects.Kind (Obj) = Version.Objects.Unknown_Object then
                  raise Ada.IO_Exceptions.Data_Error with
                    "unknown object kind: " & To_String (Current);
               end if;

               return Current;
            end;
         when Commitish =>
            return Require_Commit (Repo, Objects, Current);
         when Treeish =>
            return To_Tree (Repo, Objects, Current);
      end case;
   end Resolve;

   function Resolve_Commit
     (Repo : Version.Repository.Repository_Handle;
      Text : String)
      return Version.Objects.Hex_Object_Id is
   begin
      return Resolve (Repo, Text, Commitish);
   end Resolve_Commit;

   function Resolve_Tree
     (Repo : Version.Repository.Repository_Handle;
      Text : String)
      return Version.Objects.Hex_Object_Id is
   begin
      return Resolve (Repo, Text, Treeish);
   end Resolve_Tree;

end Version.Revisions;
