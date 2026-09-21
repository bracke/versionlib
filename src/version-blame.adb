with Ada.Containers.Ordered_Maps;
with Ada.Containers.Ordered_Sets;
with Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;
with Ada.Unchecked_Deallocation;
with Interfaces.C;
with System;

with GNAT.OS_Lib;

with Version.Diff;
with Version.Files;
with Version.Grep;
with Version.Object_Cache;
with Version.Platform;
with Version.Refs;
with Version.Rename_Detect;
with Version.Staging;
with Version.Text_Filter;
with Version.Timestamps;
with Version.Tree_Cache;

package body Version.Blame is

   use type Version.Objects.Object_Id_Storage;
   use type Version.Objects.Tree_Entry_Kind;
   use type Version.Objects.Object_Kind;

   LF : constant Character := ASCII.LF;

   function Img (N : Integer) return String is
     (Ada.Strings.Fixed.Trim (Integer'Image (N), Ada.Strings.Left));

   package Nat_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Natural);

   ---------------------------------------------------------------------
   --  Fingerprints (blame.c's struct fingerprint): a line as the multiset
   --  of its lower-cased byte pairs, whitespace folded to NUL and the
   --  string padded with whitespace at both ends, kept as a sorted
   --  (pair, count) list so that intersection and subtraction are merges.
   ---------------------------------------------------------------------

   type Pair_Count is record
      Key   : Natural := 0;   --  c0 | c1 << 8
      Count : Natural := 0;
   end record;

   package Pair_Vectors is new Ada.Containers.Vectors
     (Index_Type => Natural, Element_Type => Pair_Count);
   subtype Fingerprint is Pair_Vectors.Vector;

   package Fingerprint_Vectors is new Ada.Containers.Vectors
     (Index_Type => Natural, Element_Type => Fingerprint,
      "="        => Pair_Vectors."=");

   function Is_Space (C : Character) return Boolean is
     (C = ' ' or else C = ASCII.HT or else C = ASCII.LF
      or else C = ASCII.VT or else C = ASCII.FF or else C = ASCII.CR);

   function Is_Alnum (C : Character) return Boolean is
     (C in '0' .. '9' | 'a' .. 'z' | 'A' .. 'Z');

   function Lower_Byte (C : Character) return Natural is
     (if C in 'A' .. 'Z' then Character'Pos (C) + 32 else Character'Pos (C));

   --  git's get_fingerprint over the line (its newline included).
   function Get_Fingerprint (Line : String) return Fingerprint is
      Keys : array (1 .. Line'Length + 1) of Natural;
      N    : Natural := 0;
      C0   : Natural := 0;
      C1   : Natural;
      Hash : Natural;
   begin
      for I in Line'First .. Line'Last + 1 loop
         if I > Line'Last or else Is_Space (Line (I)) then
            C1 := 0;
         else
            C1 := Lower_Byte (Line (I));
         end if;
         Hash := C0 + C1 * 256;
         C0 := C1;
         --  Whitespace pairs are ignored.
         if Hash /= 0 then
            N := N + 1;
            Keys (N) := Hash;
         end if;
      end loop;

      --  Insertion sort: lines are short.
      for I in 2 .. N loop
         declare
            V : constant Natural := Keys (I);
            J : Natural := I;
         begin
            while J > 1 and then Keys (J - 1) > V loop
               Keys (J) := Keys (J - 1);
               J := J - 1;
            end loop;
            Keys (J) := V;
         end;
      end loop;

      return R : Fingerprint do
         for I in 1 .. N loop
            if not R.Is_Empty and then R.Last_Element.Key = Keys (I) then
               R.Reference (R.Last_Index).Count := R.Last_Element.Count + 1;
            else
               R.Append (Pair_Count'(Key => Keys (I), Count => 1));
            end if;
         end loop;
      end return;
   end Get_Fingerprint;

   --  The size of the multiset intersection.
   function Fingerprint_Similarity (A, B : Fingerprint) return Natural is
      I : Natural := A.First_Index;
      J : Natural := B.First_Index;
      S : Natural := 0;
   begin
      while I <= A.Last_Index and then J <= B.Last_Index loop
         if A (I).Key < B (J).Key then
            I := I + 1;
         elsif A (I).Key > B (J).Key then
            J := J + 1;
         else
            S := S + Natural'Min (A (I).Count, B (J).Count);
            I := I + 1;
            J := J + 1;
         end if;
      end loop;
      return S;
   end Fingerprint_Similarity;

   --  A := A - B, elementwise on counts.
   procedure Fingerprint_Subtract (A : in out Fingerprint; B : Fingerprint) is
      R : Fingerprint;
      I : Natural := A.First_Index;
      J : Natural := B.First_Index;
   begin
      while I <= A.Last_Index loop
         if J > B.Last_Index or else A (I).Key < B (J).Key then
            R.Append (A (I));
            I := I + 1;
         elsif A (I).Key > B (J).Key then
            J := J + 1;
         else
            if A (I).Count > B (J).Count then
               R.Append
                 (Pair_Count'(Key   => A (I).Key,
                              Count => A (I).Count - B (J).Count));
            end if;
            I := I + 1;
            J := J + 1;
         end if;
      end loop;
      A := R;
   end Fingerprint_Subtract;

   --  git's find_line_starts: the 0-based offset of each line, then the
   --  text length.  A last line without a newline is a line.
   function Find_Line_Starts (Text : String) return Offset_Vectors.Vector is
      R : Offset_Vectors.Vector;
      P : Natural := 0;
   begin
      while P < Text'Length loop
         R.Append (P);
         declare
            NL : Natural := 0;
         begin
            for K in Text'First + P .. Text'Last loop
               if Text (K) = LF then
                  NL := K;
                  exit;
               end if;
            end loop;
            P := (if NL = 0 then Text'Length else NL - Text'First + 1);
         end;
      end loop;
      R.Append (Text'Length);
      return R;
   end Find_Line_Starts;

   ---------------------------------------------------------------------
   --  The scoreboard.  Origins, commits and blame entries live in vectors
   --  and refer to each other by index (0 is null); the entry lists git
   --  threads through `next` pointers are threaded through Next fields,
   --  and every list head is a dummy cell so that "a link slot" is always
   --  "the Next of some cell" -- which is what git's pointer-to-pointer
   --  queue tails (dstq/srcq, blamed/unblamed) become here.
   ---------------------------------------------------------------------

   type Entry_Rec is record
      Next       : Natural := 0;
      Lno        : Natural := 0;
      Num_Lines  : Natural := 0;
      Suspect    : Natural := 0;
      S_Lno      : Natural := 0;
      Score      : Natural := 0;
      Ignored    : Boolean := False;
      Unblamable : Boolean := False;
   end record;

   package Cell_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Entry_Rec);

   type Split_Array is array (0 .. 2) of Entry_Rec;

   type Origin_Rec is record
      Commit      : Natural := 0;
      Path        : Unbounded_String;
      Blob        : Version.Objects.Object_Id_Storage :=
        Version.Objects.Zero_Object_Id;
      Mode        : Unbounded_String;
      File        : Unbounded_String;
      Have_File   : Boolean := False;
      Num_Lines   : Natural := 0;
      Prints      : Fingerprint_Vectors.Vector;
      Have_Prints : Boolean := False;
      Suspects    : Natural := 0;   --  head cell
      Previous    : Natural := 0;
      Guilty      : Boolean := False;
      Next        : Natural := 0;   --  the commit's origin chain
   end record;

   package Origin_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Origin_Rec);

   type Commit_Rec is record
      Id            : Version.Objects.Object_Id_Storage :=
        Version.Objects.Zero_Object_Id;
      Is_Fake       : Boolean := False;
      Parsed        : Boolean := False;
      Date          : Long_Long_Integer := 0;
      Tree          : Version.Objects.Object_Id_Storage :=
        Version.Objects.Zero_Object_Id;
      Parents       : Nat_Vectors.Vector;
      Children      : Nat_Vectors.Vector;
      Uninteresting : Boolean := False;
      Origins       : Natural := 0;
   end record;

   package Commit_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Commit_Rec);

   package Id_Maps is new Ada.Containers.Ordered_Maps
     (Key_Type => Version.Objects.Object_Id_Storage, Element_Type => Natural,
      "<"      => Version.Objects."<");

   package Id_Sets is new Ada.Containers.Ordered_Sets
     (Element_Type => Version.Objects.Object_Id_Storage,
      "<"          => Version.Objects."<");

   package Blob_Maps is new Ada.Containers.Ordered_Maps
     (Key_Type => Version.Objects.Object_Id_Storage,
      Element_Type => Unbounded_String, "<" => Version.Objects."<");

   package Tree_Level_Maps is new Ada.Containers.Ordered_Maps
     (Key_Type     => Version.Objects.Object_Id_Storage,
      Element_Type => Version.Objects.Tree_Entry_Vectors.Vector,
      "<"          => Version.Objects."<",
      "="          => Version.Objects.Tree_Entry_Vectors."=");

   type Queue_Item is record
      Commit : Natural := 0;
      Ctr    : Natural := 0;
   end record;

   package Queue_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Queue_Item);

   --  A guilty entry as found, for --incremental.
   type Found_Rec is record
      Origin     : Natural := 0;
      Lno        : Natural := 0;
      S_Lno      : Natural := 0;
      Num_Lines  : Natural := 0;
      Ignored    : Boolean := False;
      Unblamable : Boolean := False;
   end record;

   package Found_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Found_Rec);

   type Scoreboard is limited record
      Repo            : Version.Repository.Repository_Handle;
      --  Every object read goes through one cache: blame revisits
      --  commits, trees and blobs, and the pack index is dear to reopen.
      Objects         : Version.Object_Cache.Object_Cache;
      Opts            : Blame_Options;
      Path            : Unbounded_String;
      Cells           : Cell_Vectors.Vector;
      Origins         : Origin_Vectors.Vector;
      Commits         : Commit_Vectors.Vector;
      Commit_Map      : Id_Maps.Map;
      Queue           : Queue_Vectors.Vector;
      Queue_Ctr       : Natural := 0;
      Final           : Natural := 0;
      Final_Text      : Unbounded_String;
      Line_Starts     : Offset_Vectors.Vector;
      Num_Lines       : Natural := 0;
      Ent             : Natural := 0;   --  the finished list (no dummy)
      Found           : Found_Vectors.Vector;
      --  Commits reachable from the tip but from no bottom; when
      --  Use_Interesting, every other commit is a boundary.
      Interesting     : Id_Sets.Set;
      Use_Interesting : Boolean := False;
      Ignore          : Id_Sets.Set;
      --  The fake commit's blob, which no object store holds.
      Pretend         : Blob_Maps.Map;
      Levels          : Tree_Level_Maps.Map;
      Flat            : Version.Tree_Cache.Tree_Cache;
      Fake_Index      : Version.Staging.Index_Entry_Vectors.Vector;
      Has_Fake        : Boolean := False;
      Fake_Time       : Long_Long_Integer := 0;
      Num_Read_Blob   : Natural := 0;
      Num_Get_Patch   : Natural := 0;
      Num_Commits     : Natural := 0;
   end record;

   ---------------------------------------------------------------------
   --  Cells and lists
   ---------------------------------------------------------------------

   function New_Cell (SB : in out Scoreboard; E : Entry_Rec := (others => <>))
      return Natural is
   begin
      SB.Cells.Append (E);
      return SB.Cells.Last_Index;
   end New_Cell;

   function Next (SB : Scoreboard; Cell : Natural) return Natural is
     (SB.Cells (Cell).Next);

   procedure Set_Next (SB : in out Scoreboard; Cell, To : Natural) is
   begin
      SB.Cells.Reference (Cell).Next := To;
   end Set_Next;

   --  git's reverse_blame: reverse Head, appending Tail.
   function Reverse_Blame
     (SB : in out Scoreboard; Head, Tail : Natural) return Natural
   is
      H : Natural := Head;
      T : Natural := Tail;
   begin
      while H /= 0 loop
         declare
            N : constant Natural := Next (SB, H);
         begin
            Set_Next (SB, H, T);
            T := H;
            H := N;
         end;
      end loop;
      return T;
   end Reverse_Blame;

   --  Stable sort of a list, by (suspect, s_lno) or by final line.
   function Sort_List
     (SB : in out Scoreboard; Head : Natural; By_Suspect : Boolean)
      return Natural
   is
      Items : Nat_Vectors.Vector;
      E     : Natural := Head;

      function Before (A, B : Natural) return Boolean is
         EA : Entry_Rec renames SB.Cells (A);
         EB : Entry_Rec renames SB.Cells (B);
      begin
         if By_Suspect then
            if EA.Suspect /= EB.Suspect then
               return EA.Suspect < EB.Suspect;
            end if;
            return EA.S_Lno < EB.S_Lno;
         end if;
         return EA.Lno < EB.Lno;
      end Before;

      procedure Merge_Sort (V : in out Nat_Vectors.Vector) is
         N : constant Natural := Natural (V.Length);
      begin
         if N < 2 then
            return;
         end if;
         declare
            Mid  : constant Natural := N / 2;
            L, R : Nat_Vectors.Vector;
         begin
            for I in 1 .. Mid loop
               L.Append (V (I));
            end loop;
            for I in Mid + 1 .. N loop
               R.Append (V (I));
            end loop;
            Merge_Sort (L);
            Merge_Sort (R);
            declare
               I : Positive := 1;
               J : Positive := 1;
               K : Positive := 1;
            begin
               while I <= Natural (L.Length) or else J <= Natural (R.Length)
               loop
                  if J > Natural (R.Length)
                    or else (I <= Natural (L.Length)
                             and then not Before (R (J), L (I)))
                  then
                     V.Replace_Element (K, L (I));
                     I := I + 1;
                  else
                     V.Replace_Element (K, R (J));
                     J := J + 1;
                  end if;
                  K := K + 1;
               end loop;
            end;
         end;
      end Merge_Sort;
   begin
      while E /= 0 loop
         Items.Append (E);
         E := Next (SB, E);
      end loop;
      Merge_Sort (Items);
      for I in 1 .. Natural (Items.Length) loop
         Set_Next
           (SB, Items (I),
            (if I < Natural (Items.Length) then Items (I + 1) else 0));
      end loop;
      return (if Items.Is_Empty then 0 else Items.First_Element);
   end Sort_List;

   --  git's blame_merge: merge two lists sorted by s_lno.
   function Blame_Merge
     (SB : in out Scoreboard; List1, List2 : Natural) return Natural
   is
      P1   : Natural := List1;
      P2   : Natural := List2;
      Head : Natural;
      Tail : Natural;   --  cell whose Next is the link to fill
   begin
      if P1 = 0 then
         return P2;
      elsif P2 = 0 then
         return P1;
      end if;
      Head := New_Cell (SB);
      Tail := Head;
      while P1 /= 0 and then P2 /= 0 loop
         if SB.Cells (P1).S_Lno <= SB.Cells (P2).S_Lno then
            Set_Next (SB, Tail, P1);
            Tail := P1;
            P1 := Next (SB, P1);
         else
            Set_Next (SB, Tail, P2);
            Tail := P2;
            P2 := Next (SB, P2);
         end if;
      end loop;
      Set_Next (SB, Tail, (if P1 /= 0 then P1 else P2));
      return Next (SB, Head);
   end Blame_Merge;

   ---------------------------------------------------------------------
   --  Commits and origins
   ---------------------------------------------------------------------

   function Lookup_Commit
     (SB : in out Scoreboard; Id : Version.Objects.Object_Id_Storage)
      return Natural
   is
      C : constant Id_Maps.Cursor := SB.Commit_Map.Find (Id);
   begin
      if Id_Maps.Has_Element (C) then
         return Id_Maps.Element (C);
      end if;
      SB.Commits.Append (Commit_Rec'(Id => Id, others => <>));
      SB.Commit_Map.Insert (Id, SB.Commits.Last_Index);
      return SB.Commits.Last_Index;
   end Lookup_Commit;

   --  git's repo_parse_commit: date, tree and parents (grafts first).
   procedure Parse_Commit (SB : in out Scoreboard; C : Natural) is
      Rec : Commit_Rec := SB.Commits (C);
   begin
      if Rec.Parsed then
         return;
      end if;
      declare
         Obj     : constant Version.Objects.Git_Object :=
           Version.Object_Cache.Read_Object (SB.Repo, SB.Objects, Rec.Id);
         Parents : Version.Objects.Object_Id_Vectors.Vector :=
           Version.Objects.Commit_Parent_Ids (Obj);
      begin
         if Version.Objects.Kind (Obj) /= Version.Objects.Commit_Object then
            raise Ada.IO_Exceptions.Data_Error with "not a commit";
         end if;
         Rec.Date := Version.Objects.Commit_Committer_Time (Obj);
         Rec.Tree := Version.Objects.Commit_Tree_Id (Obj);
         for G of SB.Opts.Grafts loop
            if G.Commit = Rec.Id then
               Parents := G.Parents;
            end if;
         end loop;
         Rec.Parsed := True;
         SB.Commits.Replace_Element (C, Rec);
         for P of Parents loop
            declare
               PI : constant Natural := Lookup_Commit (SB, P);
            begin
               SB.Commits.Reference (C).Parents.Append (PI);
            end;
         end loop;
      end;
   end Parse_Commit;

   function Make_Origin
     (SB : in out Scoreboard; C : Natural; Path : String) return Natural
   is
      Head : constant Natural := New_Cell (SB);
   begin
      SB.Origins.Append
        (Origin_Rec'(Commit   => C,
                     Path     => To_Unbounded_String (Path),
                     Suspects => Head,
                     Next     => SB.Commits (C).Origins,
                     others   => <>));
      SB.Commits.Reference (C).Origins := SB.Origins.Last_Index;
      return SB.Origins.Last_Index;
   end Make_Origin;

   function Get_Origin
     (SB : in out Scoreboard; C : Natural; Path : String) return Natural
   is
      O : Natural := SB.Commits (C).Origins;
   begin
      while O /= 0 loop
         if To_String (SB.Origins (O).Path) = Path then
            return O;
         end if;
         O := SB.Origins (O).Next;
      end loop;
      return Make_Origin (SB, C, Path);
   end Get_Origin;

   function Suspects (SB : Scoreboard; O : Natural) return Natural is
     (Next (SB, SB.Origins (O).Suspects));

   function Is_Uninteresting (SB : Scoreboard; C : Natural) return Boolean is
      Rec : Commit_Rec renames SB.Commits (C);
   begin
      return Rec.Uninteresting
        or else (SB.Use_Interesting and then not Rec.Is_Fake
                 and then not SB.Interesting.Contains (Rec.Id));
   end Is_Uninteresting;

   --  git's mark_parents_uninteresting, over the commits already parsed.
   procedure Mark_Parents_Uninteresting (SB : in out Scoreboard; C : Natural)
   is
      Stack : Nat_Vectors.Vector;
   begin
      for P of SB.Commits (C).Parents loop
         Stack.Append (P);
      end loop;
      while not Stack.Is_Empty loop
         declare
            X : Natural := Stack.Last_Element;
         begin
            Stack.Delete_Last;
            while X /= 0 loop
               exit when SB.Commits (X).Uninteresting;
               SB.Commits.Reference (X).Uninteresting := True;
               exit when not SB.Commits (X).Parsed
                 or else SB.Commits (X).Parents.Is_Empty;
               for K in 2 .. Natural (SB.Commits (X).Parents.Length) loop
                  Stack.Append (SB.Commits (X).Parents (K));
               end loop;
               X := SB.Commits (X).Parents.First_Element;
            end loop;
         end;
      end loop;
   end Mark_Parents_Uninteresting;

   --  git's first_scapegoat: the parents (first only under --first-parent),
   --  or the children under --reverse.
   function Scapegoats (SB : Scoreboard; C : Natural) return Nat_Vectors.Vector
   is
      Rec : Commit_Rec renames SB.Commits (C);
   begin
      if SB.Opts.Reverse_Blame then
         return Rec.Children;
      elsif SB.Opts.First_Parent and then Natural (Rec.Parents.Length) > 1 then
         return R : Nat_Vectors.Vector do
            R.Append (Rec.Parents.First_Element);
         end return;
      end if;
      return Rec.Parents;
   end Scapegoats;

   ---------------------------------------------------------------------
   --  The priority queue of commits with unassigned entries: newest
   --  commit date first (oldest under --reverse), first in first out
   --  among equal dates.
   ---------------------------------------------------------------------

   procedure Queue_Put (SB : in out Scoreboard; C : Natural) is
   begin
      SB.Queue.Append (Queue_Item'(Commit => C, Ctr => SB.Queue_Ctr));
      SB.Queue_Ctr := SB.Queue_Ctr + 1;
   end Queue_Put;

   function Queue_Get (SB : in out Scoreboard) return Natural is
      Best : Natural := 0;
   begin
      for I in 1 .. Natural (SB.Queue.Length) loop
         if Best = 0 then
            Best := I;
         else
            declare
               DI    : constant Long_Long_Integer :=
                 SB.Commits (SB.Queue (I).Commit).Date;
               DB    : constant Long_Long_Integer :=
                 SB.Commits (SB.Queue (Best).Commit).Date;
               Ahead : constant Boolean :=
                 (if SB.Opts.Reverse_Blame then DI < DB else DI > DB);
            begin
               if Ahead
                 or else (DI = DB
                          and then SB.Queue (I).Ctr < SB.Queue (Best).Ctr)
               then
                  Best := I;
               end if;
            end;
         end if;
      end loop;
      if Best = 0 then
         return 0;
      end if;
      return C : constant Natural := SB.Queue (Best).Commit do
         SB.Queue.Delete (Best);
      end return;
   end Queue_Get;

   ---------------------------------------------------------------------
   --  Trees, blobs and the fake index
   ---------------------------------------------------------------------

   function Read_Blob
     (SB : in out Scoreboard; Id : Version.Objects.Object_Id_Storage)
      return String
   is
      P : constant Blob_Maps.Cursor := SB.Pretend.Find (Id);
   begin
      if Blob_Maps.Has_Element (P) then
         return To_String (Blob_Maps.Element (P));
      end if;
      return Version.Objects.Content
        (Version.Object_Cache.Read_Object (SB.Repo, SB.Objects, Id));
   end Read_Blob;

   --  A blob's text as blame sees it: through the path's textconv filter
   --  when one applies.
   function Blob_Text
     (SB : in out Scoreboard; Path : String;
      Id : Version.Objects.Object_Id_Storage) return String
   is
      Raw : constant String := Read_Blob (SB, Id);
   begin
      if SB.Opts.Textconv then
         declare
            Cmd : constant String :=
              Version.Diff.Textconv_Command (SB.Repo, Path);
         begin
            if Cmd /= "" then
               return Version.Diff.Run_Textconv (Cmd, Raw);
            end if;
         end;
      end if;
      return Raw;
   end Blob_Text;

   function Tree_Level
     (SB : in out Scoreboard; Tree : Version.Objects.Object_Id_Storage)
      return Version.Objects.Tree_Entry_Vectors.Vector
   is
      C : constant Tree_Level_Maps.Cursor := SB.Levels.Find (Tree);
   begin
      if Tree_Level_Maps.Has_Element (C) then
         return Tree_Level_Maps.Element (C);
      end if;
      declare
         Obj : constant Version.Objects.Git_Object :=
           Version.Object_Cache.Read_Object (SB.Repo, SB.Objects, Tree);
         E   : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Version.Objects.Parse_Tree
             (Version.Repository.Algorithm (SB.Repo),
              Version.Objects.Content (Obj));
      begin
         SB.Levels.Insert (Tree, E);
         return E;
      end;
   end Tree_Level;

   --  The mode's file type: git compares S_IFMT to tell a type change
   --  from a modification.
   function Type_Bits (Mode : String) return String is
      M : constant String :=
        (if Mode'Length < 6 then [1 .. 6 - Mode'Length => '0'] & Mode
         else Mode);
   begin
      return M (M'First .. M'First + 2);
   end Type_Bits;

   function Is_Gitlink (Mode : String) return Boolean is
     (Type_Bits (Mode) = "160");

   --  git's get_tree_entry (or the index lookup for the fake commit).
   procedure Lookup_Path
     (SB    : in out Scoreboard;
      C     : Natural;
      Path  : String;
      Found : out Boolean;
      Id    : out Version.Objects.Object_Id_Storage;
      Mode  : out Unbounded_String;
      Kind  : out Version.Objects.Tree_Entry_Kind)
   is
   begin
      Found := False;
      Id := Version.Objects.Zero_Object_Id;
      Mode := Null_Unbounded_String;
      Kind := Version.Objects.Tree_Blob;

      if SB.Commits (C).Is_Fake then
         for E of SB.Fake_Index loop
            if To_String (E.Path) = Path then
               Found := True;
               Id := E.Id;
               Mode := E.Mode;
               Kind :=
                 (if Is_Gitlink (To_String (E.Mode))
                  then Version.Objects.Tree_Gitlink
                  else Version.Objects.Tree_Blob);
               return;
            end if;
         end loop;
         return;
      end if;

      Parse_Commit (SB, C);
      declare
         Tree  : Version.Objects.Object_Id_Storage := SB.Commits (C).Tree;
         Start : Positive := Path'First;
      begin
         loop
            declare
               Stop : Natural := Path'Last + 1;
            begin
               for K in Start .. Path'Last loop
                  if Path (K) = '/' then
                     Stop := K;
                     exit;
                  end if;
               end loop;
               declare
                  Name  : constant String := Path (Start .. Stop - 1);
                  Level : constant Version.Objects.Tree_Entry_Vectors.Vector :=
                    Tree_Level (SB, Tree);
                  Hit   : Boolean := False;
               begin
                  for E of Level loop
                     if To_String (E.Path) = Name then
                        Hit := True;
                        if Stop > Path'Last then
                           Found := True;
                           Id := E.Id;
                           Mode := E.Mode;
                           Kind := E.Kind;
                           return;
                        elsif E.Kind = Version.Objects.Tree_Directory then
                           Tree := E.Id;
                        else
                           return;
                        end if;
                        exit;
                     end if;
                  end loop;
                  if not Hit then
                     return;
                  end if;
               end;
               Start := Stop + 1;
            end;
         end loop;
      end;
   end Lookup_Path;

   --  Every blob and gitlink of a commit's tree (the fake commit's index),
   --  in path order.
   function Flat_Blobs
     (SB : in out Scoreboard; C : Natural)
      return Version.Objects.Tree_Entry_Vectors.Vector
   is
      R : Version.Objects.Tree_Entry_Vectors.Vector;
   begin
      if SB.Commits (C).Is_Fake then
         for E of SB.Fake_Index loop
            R.Append
              (Version.Objects.Tree_Entry'
                 (Path => E.Path,
                  Id   => E.Id,
                  Kind =>
                    (if Is_Gitlink (To_String (E.Mode))
                     then Version.Objects.Tree_Gitlink
                     else Version.Objects.Tree_Blob),
                  Mode => E.Mode));
         end loop;
         return R;
      end if;
      Parse_Commit (SB, C);
      declare
         Flat : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Version.Tree_Cache.Flatten_Tree (SB.Repo, SB.Flat, SB.Commits (C).Tree);
      begin
         for E of Flat loop
            if E.Kind /= Version.Objects.Tree_Directory then
               R.Append (E);
            end if;
         end loop;
      end;
      return R;
   end Flat_Blobs;

   --  The position of Path in a flat listing (its index plus one), 0 when
   --  absent.
   function Find_Flat
     (V : Version.Objects.Tree_Entry_Vectors.Vector; Path : String)
      return Natural
   is
   begin
      for I in V.First_Index .. V.Last_Index loop
         if To_String (V (I).Path) = Path then
            return I + 1;
         end if;
      end loop;
      return 0;
   end Find_Flat;

   --  git's fill_origin_blob (with fill_fingerprints).
   procedure Fill_Origin_Blob
     (SB : in out Scoreboard; O : Natural; Prints : Boolean) is
   begin
      if not SB.Origins (O).Have_File then
         SB.Num_Read_Blob := SB.Num_Read_Blob + 1;
         declare
            Text : constant String :=
              Blob_Text (SB, To_String (SB.Origins (O).Path), SB.Origins (O).Blob);
         begin
            SB.Origins.Reference (O).File := To_Unbounded_String (Text);
            SB.Origins.Reference (O).Have_File := True;
         end;
      end if;
      if Prints and then not SB.Origins (O).Have_Prints then
         declare
            Text   : constant String := To_String (SB.Origins (O).File);
            Starts : constant Offset_Vectors.Vector := Find_Line_Starts (Text);
            FP     : Fingerprint_Vectors.Vector;
         begin
            for I in 0 .. Natural (Starts.Length) - 2 loop
               FP.Append
                 (Get_Fingerprint
                    (Text (Text'First + Starts (I)
                           .. Text'First + Starts (I + 1) - 1)));
            end loop;
            SB.Origins.Reference (O).Prints := FP;
            SB.Origins.Reference (O).Num_Lines := Natural (Starts.Length) - 1;
            SB.Origins.Reference (O).Have_Prints := True;
         end;
      end if;
   end Fill_Origin_Blob;

   procedure Drop_Origin_Blob (SB : in out Scoreboard; O : Natural) is
      R : Origin_Rec renames SB.Origins.Reference (O);
   begin
      R.File := Null_Unbounded_String;
      R.Have_File := False;
      R.Prints.Clear;
      R.Have_Prints := False;
      R.Num_Lines := 0;
   end Drop_Origin_Blob;

   function Nth_Line_Offset (SB : Scoreboard; Lno : Natural) return Natural is
     (SB.Line_Starts (Natural'Min (Lno, SB.Num_Lines)));

   --  The final image's lines From .. To (0-based, half-open).
   function Final_Slice (SB : Scoreboard; From, To : Natural) return String is
     (Slice (SB.Final_Text, Nth_Line_Offset (SB, From) + 1,
             Nth_Line_Offset (SB, To)));

   --  git's blame_entry_score: one plus the alphanumerics in the lines.
   function Entry_Score (SB : Scoreboard; E : in out Entry_Rec) return Natural
   is
   begin
      if E.Score /= 0 then
         return E.Score;
      end if;
      declare
         Score : Natural := 1;
      begin
         for C of Final_Slice (SB, E.Lno, E.Lno + E.Num_Lines) loop
            if Is_Alnum (C) then
               Score := Score + 1;
            end if;
         end loop;
         E.Score := Score;
         return Score;
      end;
   end Entry_Score;

   function Cell_Score (SB : in out Scoreboard; Cell : Natural) return Natural
   is
      E : Entry_Rec := SB.Cells (Cell);
      S : constant Natural := Entry_Score (SB, E);
   begin
      SB.Cells.Reference (Cell).Score := S;
      return S;
   end Cell_Score;

   function Changes_Between
     (SB : Scoreboard; Old_Text, New_Text : String)
      return Version.Merge.Text_Change_Vectors.Vector
   is (Version.Merge.Text_Changes
         (Old_Text, New_Text,
          Algorithm        => SB.Opts.Algorithm,
          Indent_Heuristic => SB.Opts.Indent_Heuristic,
          Whitespace       => SB.Opts.Whitespace));

   ---------------------------------------------------------------------
   --  Queueing blame to origins
   ---------------------------------------------------------------------

   --  git's queue_blames: merge Sorted into porigin's suspects, queueing
   --  its commit unless another of the commit's origins already waits.
   procedure Queue_Blames (SB : in out Scoreboard; PO, Sorted : Natural) is
      Head : constant Natural := SB.Origins (PO).Suspects;
   begin
      if Next (SB, Head) /= 0 then
         Set_Next (SB, Head, Blame_Merge (SB, Next (SB, Head), Sorted));
         return;
      end if;
      declare
         C : constant Natural := SB.Origins (PO).Commit;
         O : Natural := SB.Commits (C).Origins;
      begin
         while O /= 0 loop
            if Suspects (SB, O) /= 0 then
               Set_Next (SB, Head, Sorted);
               return;
            end if;
            O := SB.Origins (O).Next;
         end loop;
         Set_Next (SB, Head, Sorted);
         Queue_Put (SB, C);
      end;
   end Queue_Blames;

   --  git's distribute_blame: hand an unsorted list out to its origins.
   procedure Distribute_Blame (SB : in out Scoreboard; Blamed : Natural) is
      B : Natural := Sort_List (SB, Blamed, By_Suspect => True);
   begin
      while B /= 0 loop
         declare
            PO   : constant Natural := SB.Cells (B).Suspect;
            Susp : Natural := 0;
         begin
            loop
               declare
                  N : constant Natural := Next (SB, B);
               begin
                  Set_Next (SB, B, Susp);
                  Susp := B;
                  B := N;
               end;
               exit when B = 0 or else SB.Cells (B).Suspect /= PO;
            end loop;
            Queue_Blames (SB, PO, Reverse_Blame (SB, Susp, 0));
         end;
      end loop;
   end Distribute_Blame;

   ---------------------------------------------------------------------
   --  Splitting entries
   ---------------------------------------------------------------------

   --  git's add_blame_entry: a copy of Src at slot Q, which then advances.
   procedure Add_Blame_Entry
     (SB : in out Scoreboard; Q : in out Natural; Src : Entry_Rec)
   is
      E : Entry_Rec := Src;
   begin
      E.Next := Next (SB, Q);
      declare
         N : constant Natural := New_Cell (SB, E);
      begin
         Set_Next (SB, Q, N);
         Q := N;
      end;
   end Add_Blame_Entry;

   --  git's dup_entry: Dst takes Src's content and is linked at slot Q.
   procedure Dup_Entry
     (SB : in out Scoreboard; Q : in out Natural; Dst : Natural; Src : Entry_Rec)
   is
      E : Entry_Rec := Src;
   begin
      E.Next := Next (SB, Q);
      SB.Cells.Replace_Element (Dst, E);
      Set_Next (SB, Q, Dst);
      Q := Dst;
   end Dup_Entry;

   --  git's split_overlap: lines tlno..same of e came from the parent,
   --  where parent line plno is e's line tlno.
   procedure Split_Overlap
     (Split            : out Split_Array;
      E                : Entry_Rec;
      Tlno, Plno, Same : Integer;
      Parent           : Natural)
   is
      Chunk_End_Lno : Integer;
   begin
      Split := [others => (others => <>)];
      for I in Split'Range loop
         Split (I).Ignored := E.Ignored;
         Split (I).Unblamable := E.Unblamable;
      end loop;

      if E.S_Lno < Tlno then
         Split (0).Suspect := E.Suspect;
         Split (0).Lno := E.Lno;
         Split (0).S_Lno := E.S_Lno;
         Split (0).Num_Lines := Tlno - E.S_Lno;
         Split (1).Lno := E.Lno + Tlno - E.S_Lno;
         Split (1).S_Lno := Plno;
      else
         Split (1).Lno := E.Lno;
         Split (1).S_Lno := Plno + (E.S_Lno - Tlno);
      end if;

      if Same < E.S_Lno + E.Num_Lines then
         Split (2).Suspect := E.Suspect;
         Split (2).Lno := E.Lno + (Same - E.S_Lno);
         Split (2).S_Lno := E.S_Lno + (Same - E.S_Lno);
         Split (2).Num_Lines := E.S_Lno + E.Num_Lines - Same;
         Chunk_End_Lno := Split (2).Lno;
      else
         Chunk_End_Lno := E.Lno + E.Num_Lines;
      end if;
      if Chunk_End_Lno - Split (1).Lno < 1 then
         return;
      end if;
      Split (1).Num_Lines := Chunk_End_Lno - Split (1).Lno;
      Split (1).Suspect := Parent;
   end Split_Overlap;

   --  git's split_blame: move the parts to the blamed/unblamed queues.
   procedure Split_Blame
     (SB               : in out Scoreboard;
      Blamed, Unblamed : in out Natural;
      Split            : Split_Array;
      E                : Natural) is
   begin
      if Split (0).Suspect /= 0 and then Split (2).Suspect /= 0 then
         Dup_Entry (SB, Unblamed, E, Split (0));
         Add_Blame_Entry (SB, Unblamed, Split (2));
         Add_Blame_Entry (SB, Blamed, Split (1));
      elsif Split (0).Suspect = 0 and then Split (2).Suspect = 0 then
         Dup_Entry (SB, Blamed, E, Split (1));
      elsif Split (0).Suspect /= 0 then
         Dup_Entry (SB, Unblamed, E, Split (0));
         Add_Blame_Entry (SB, Blamed, Split (1));
      else
         Dup_Entry (SB, Blamed, E, Split (1));
         Add_Blame_Entry (SB, Unblamed, Split (2));
      end if;
   end Split_Blame;

   --  git's split_blame_at: E keeps Len lines, the rest goes to a new
   --  cell (returned) with the given suspect.
   function Split_Blame_At
     (SB : in out Scoreboard; E : Natural; Len : Natural; New_Suspect : Natural)
      return Natural
   is
      N : Entry_Rec;
   begin
      declare
         R : Entry_Rec renames SB.Cells.Reference (E);
      begin
         N.Suspect := New_Suspect;
         N.Ignored := R.Ignored;
         N.Unblamable := R.Unblamable;
         N.Lno := R.Lno + Len;
         N.S_Lno := R.S_Lno + Len;
         N.Num_Lines := R.Num_Lines - Len;
         R.Num_Lines := Len;
         R.Score := 0;
      end;
      return New_Cell (SB, N);
   end Split_Blame_At;

   --  git's copy_split_if_better.
   procedure Copy_Split_If_Better
     (SB        : Scoreboard;
      Best      : in out Split_Array;
      Potential : in out Split_Array)
   is
   begin
      if Potential (1).Suspect = 0 then
         return;
      end if;
      if Best (1).Suspect /= 0
        and then Entry_Score (SB, Potential (1)) < Entry_Score (SB, Best (1))
      then
         return;
      end if;
      Best := Potential;
   end Copy_Split_If_Better;

   ---------------------------------------------------------------------
   --  Fuzzy line matching for --ignore-rev (blame.c's fingerprint
   --  machinery, indices standing in for its pointer arithmetic)
   ---------------------------------------------------------------------

   Certain_Nothing_Matches  : constant Integer := -2;
   Certainty_Not_Calculated : constant Integer := -1;

   type Int_Array is array (Natural range <>) of Integer;
   type Int_Array_Access is access Int_Array;
   procedure Free is new Ada.Unchecked_Deallocation (Int_Array, Int_Array_Access);

   type Line_Mapping is record
      Destination_Start, Destination_Length : Integer;
      Source_Start, Source_Length           : Integer;
   end record;

   function Map_Line_Number (Line : Integer; M : Line_Mapping) return Integer
   is (((Line - M.Source_Start) * 2 + 1) * M.Destination_Length
       / (M.Source_Length * 2) + M.Destination_Start);

   --  git's fuzzy_find_matching_lines: for each target line in
   --  tlno..same, the best matching parent line in parent_slno..+len,
   --  or -1.  Modifies the parent's fingerprints (subtracting matches).
   function Fuzzy_Find_Matching_Lines
     (SB          : in out Scoreboard;
      Parent      : Natural;
      Target      : Natural;
      Tlno        : Integer;
      Parent_Slno : Integer;
      Same        : Integer;
      Parent_Len  : Integer)
      return Int_Array_Access
   is
      Whole_A_Start  : constant Integer := Parent_Slno;
      Whole_A_Length : constant Integer := Parent_Len;
      Whole_B_Start  : constant Integer := Tlno;
      Whole_B_Length : constant Integer := Same - Tlno;
      Map            : constant Line_Mapping :=
        (Whole_A_Start, Whole_A_Length, Whole_B_Start, Whole_B_Length);
      Max_A          : Integer := 10;
      Max_B          : Integer;
   begin
      if Whole_A_Length <= 0 then
         return null;
      end if;
      if Max_A >= Whole_A_Length then
         Max_A := Whole_A_Length - 1;
      end if;
      Max_B := ((2 * Max_A + 1) * Whole_B_Length - 1) / Whole_A_Length;

      declare
         Row          : constant Integer := Max_A * 2 + 1;
         Result       : constant Int_Array_Access :=
           new Int_Array'(0 .. Whole_B_Length - 1 => -1);
         Second_Best  : Int_Array (0 .. Whole_B_Length - 1) := [others => -1];
         Certainties  : Int_Array (0 .. Whole_B_Length - 1) :=
           [others => Certainty_Not_Calculated];
         Similarities : Int_Array (0 .. Whole_B_Length * Row - 1) :=
           [others => -1];

         --  similarities[line_a - closest + max_a + local_b * row]
         function Sim_Index
           (Sim_Off, Line_A, Local_B, Closest_A : Integer) return Integer
         is (Sim_Off + Line_A - Closest_A + Max_A + Local_B * Row);

         procedure Find_Best_Line_Matches
           (A_Start, A_Length, B_Start       : Integer;
            Local_B                          : Integer;
            FA_Off, FB_Off, Sim_Off, R_Off   : Integer)
         is
            Closest_A    : constant Integer :=
              Map_Line_Number (Local_B + B_Start, Map) - A_Start;
            Search_Start : Integer := Closest_A - Max_A;
            Search_End   : Integer := Closest_A + Max_A + 1;
            Best_Sim, Second_Sim : Integer := 0;
            Best_Idx, Second_Idx : Integer := 0;
         begin
            if Certainties (R_Off + Local_B) /= Certainty_Not_Calculated then
               return;
            end if;
            if Search_Start < 0 then
               Search_Start := 0;
            end if;
            if Search_End > A_Length then
               Search_End := A_Length;
            end if;
            for I in Search_Start .. Search_End - 1 loop
               declare
                  K : constant Integer :=
                    Sim_Index (Sim_Off, I, Local_B, Closest_A);
               begin
                  if Similarities (K) = -1 then
                     Similarities (K) :=
                       Fingerprint_Similarity
                         (SB.Origins (Target).Prints (FB_Off + Local_B),
                          SB.Origins (Parent).Prints (FA_Off + I))
                       * (1000 - abs (I - Closest_A));
                  end if;
                  if Similarities (K) > Best_Sim then
                     Second_Sim := Best_Sim;
                     Second_Idx := Best_Idx;
                     Best_Sim := Similarities (K);
                     Best_Idx := I;
                  elsif Similarities (K) > Second_Sim then
                     Second_Sim := Similarities (K);
                     Second_Idx := I;
                  end if;
               end;
            end loop;
            if Best_Sim = 0 then
               Certainties (R_Off + Local_B) := Certain_Nothing_Matches;
               Result (R_Off + Local_B) := -1;
            else
               Certainties (R_Off + Local_B) := Best_Sim * 2 - Second_Sim;
               Result (R_Off + Local_B) := A_Start + Best_Idx;
               Second_Best (R_Off + Local_B) := A_Start + Second_Idx;
            end if;
         end Find_Best_Line_Matches;

         procedure Recurse
           (A_Start, B_Start, A_Length, B_Length : Integer;
            FA_Off, FB_Off, Sim_Off, R_Off       : Integer)
         is
            Most_Certain_B         : Integer := -1;
            Most_Certain_Certainty : Integer := -1;
            Most_Certain_A         : Integer;
            Inv_Min, Inv_Max       : Integer;
         begin
            for I in 0 .. B_Length - 1 loop
               Find_Best_Line_Matches
                 (A_Start, A_Length, B_Start, I, FA_Off, FB_Off, Sim_Off, R_Off);
               if Certainties (R_Off + I) > Most_Certain_Certainty then
                  Most_Certain_Certainty := Certainties (R_Off + I);
                  Most_Certain_B := I;
               end if;
            end loop;
            if Most_Certain_B = -1 then
               return;
            end if;
            Most_Certain_A := Result (R_Off + Most_Certain_B);

            declare
               B_Print : constant Fingerprint :=
                 SB.Origins (Target).Prints (FB_Off + Most_Certain_B);
            begin
               Fingerprint_Subtract
                 (SB.Origins.Reference (Parent).Prints.Reference
                    (FA_Off + Most_Certain_A - A_Start),
                  B_Print);
            end;

            Inv_Min := Most_Certain_B - Max_B;
            Inv_Max := Most_Certain_B + Max_B + 1;
            if Inv_Min < 0 then
               Inv_Min := 0;
            end if;
            if Inv_Max > B_Length then
               Inv_Max := B_Length;
            end if;

            for I in Inv_Min .. Inv_Max - 1 loop
               declare
                  Closest_A : constant Integer :=
                    Map_Line_Number (I + B_Start, Map) - A_Start;
               begin
                  if abs (Most_Certain_A - A_Start - Closest_A) <= Max_A then
                     Similarities
                       (Sim_Index
                          (Sim_Off, Most_Certain_A - A_Start, I, Closest_A)) :=
                       -1;
                  end if;
               end;
            end loop;

            for I in reverse Inv_Min .. Most_Certain_B - 1 loop
               if Certainties (R_Off + I) >= 0
                 and then (Result (R_Off + I) >= Most_Certain_A
                           or else Second_Best (R_Off + I) >= Most_Certain_A)
               then
                  Certainties (R_Off + I) := Certainty_Not_Calculated;
               end if;
            end loop;
            for I in Most_Certain_B + 1 .. Inv_Max - 1 loop
               if Certainties (R_Off + I) >= 0
                 and then (Result (R_Off + I) <= Most_Certain_A
                           or else Second_Best (R_Off + I) <= Most_Certain_A)
               then
                  Certainties (R_Off + I) := Certainty_Not_Calculated;
               end if;
            end loop;

            if Most_Certain_B > 0 then
               Recurse
                 (A_Start, B_Start,
                  Most_Certain_A + 1 - A_Start, Most_Certain_B,
                  FA_Off, FB_Off, Sim_Off, R_Off);
            end if;
            if Most_Certain_B + 1 < B_Length then
               declare
                  Second_A_Start : constant Integer := Most_Certain_A;
                  Offset_B       : constant Integer := Most_Certain_B + 1;
                  Second_B_Start : constant Integer := B_Start + Offset_B;
               begin
                  Recurse
                    (Second_A_Start, Second_B_Start,
                     A_Length + A_Start - Second_A_Start,
                     B_Length + B_Start - Second_B_Start,
                     FA_Off + Second_A_Start - A_Start,
                     FB_Off + Offset_B,
                     Sim_Off + Offset_B * Row,
                     R_Off + Offset_B);
               end;
            end if;
         end Recurse;
      begin
         Recurse (Whole_A_Start, Whole_B_Start, Whole_A_Length, Whole_B_Length,
                  Whole_A_Start, Whole_B_Start, 0, 0);
         return Result;
      end;
   end Fuzzy_Find_Matching_Lines;

   type Line_Tracker is record
      Is_Parent : Boolean := False;
      S_Lno     : Natural := 0;
   end record;
   type Tracker_Array is array (Natural range <>) of Line_Tracker;

   --  git's scan_parent_range: the most similar parent line (at least
   --  the file threshold), ties to the nearest line number.
   function Scan_Parent_Range
     (SB : Scoreboard; Parent, Target : Natural; T_Idx : Natural)
      return Integer
   is
      Threshold : constant Natural := 10;
      Best_Val  : Natural := Threshold;
      Best_Idx  : Integer := -1;
   begin
      for P_Idx in 0 .. SB.Origins (Parent).Num_Lines - 1 loop
         declare
            Sim : constant Natural :=
              Fingerprint_Similarity
                (SB.Origins (Target).Prints (T_Idx),
                 SB.Origins (Parent).Prints (P_Idx));
         begin
            if Sim >= Best_Val
              and then not (Sim = Best_Val and then Best_Idx /= -1
                            and then abs (Best_Idx - T_Idx) < abs (P_Idx - T_Idx))
            then
               Best_Val := Sim;
               Best_Idx := P_Idx;
            end if;
         end;
      end loop;
      return Best_Idx;
   end Scan_Parent_Range;

   procedure Guess_Line_Blames
     (SB          : in out Scoreboard;
      Parent      : Natural;
      Target      : Natural;
      Tlno, Offset, Same, Parent_Len : Integer;
      Line_Blames : in out Tracker_Array)
   is
      Parent_Slno : constant Integer := Tlno + Offset;
      Fuzzy       : Int_Array_Access :=
        Fuzzy_Find_Matching_Lines
          (SB, Parent, Target, Tlno, Parent_Slno, Same, Parent_Len);
   begin
      for I in 0 .. Same - Tlno - 1 loop
         declare
            Target_Idx : constant Natural := Tlno + I;
            Best_Idx   : Integer;
         begin
            if Fuzzy /= null and then Fuzzy (I) >= 0 then
               Best_Idx := Fuzzy (I);
            else
               Best_Idx := Scan_Parent_Range (SB, Parent, Target, Target_Idx);
            end if;
            if Best_Idx >= 0 then
               Line_Blames (I) := (Is_Parent => True, S_Lno => Best_Idx);
            else
               Line_Blames (I) := (Is_Parent => False, S_Lno => Target_Idx);
            end if;
         end;
      end loop;
      Free (Fuzzy);
   end Guess_Line_Blames;

   --  git's ignore_blame_entry: carve E into runs that go to the parent
   --  (ignored) or stay with the target (unblamable).
   procedure Ignore_Blame_Entry
     (SB              : in out Scoreboard;
      E_In            : Natural;
      Parent          : Natural;
      Diffp, Ignoredp : in out Natural;
      Line_Blames     : Tracker_Array;
      Base            : Natural)
   is
      E         : Natural := E_In;
      Entry_Len : Natural := 1;
      Nr_Lines  : constant Natural := SB.Cells (E).Num_Lines;
   begin
      for I in 0 .. Nr_Lines - 1 loop
         declare
            Nxt  : Natural := 0;
            Skip : Boolean := False;
         begin
            if I + 1 < Nr_Lines then
               if Line_Blames (Base + I).Is_Parent
                    = Line_Blames (Base + I + 1).Is_Parent
                 and then Line_Blames (Base + I).S_Lno + 1
                          = Line_Blames (Base + I + 1).S_Lno
               then
                  Entry_Len := Entry_Len + 1;
                  Skip := True;
               else
                  declare
                     Susp : constant Natural := SB.Cells (E).Suspect;
                  begin
                     Nxt := Split_Blame_At (SB, E, Entry_Len, Susp);
                  end;
               end if;
            end if;
            if not Skip then
               if Line_Blames (Base + I).Is_Parent then
                  SB.Cells.Reference (E).Ignored := True;
                  SB.Cells.Reference (E).Suspect := Parent;
                  SB.Cells.Reference (E).S_Lno :=
                    Line_Blames (Base + I - Entry_Len + 1).S_Lno;
                  Set_Next (SB, E, Ignoredp);
                  Ignoredp := E;
               else
                  SB.Cells.Reference (E).Unblamable := True;
                  Set_Next (SB, E, Diffp);
                  Diffp := E;
               end if;
               E := Nxt;
               Entry_Len := 1;
            end if;
         end;
      end loop;
   end Ignore_Blame_Entry;

   ---------------------------------------------------------------------
   --  Passing blame to a parent along the diff
   ---------------------------------------------------------------------

   --  git's blame_chunk: lines before tlno are the parent's (shifted by
   --  offset); tlno..same differ and stay with the target.
   procedure Blame_Chunk
     (SB           : in out Scoreboard;
      Dstq, Srcq   : in out Natural;
      Tlno, Offset, Same, Parent_Len : Integer;
      Parent       : Natural;
      Target       : Natural;
      Ignore_Diffs : Boolean)
   is
      E        : Natural := Next (SB, Srcq);
      Samep    : Natural := 0;
      Diffp    : Natural := 0;
      Ignoredp : Natural := 0;
   begin
      while E /= 0 and then SB.Cells (E).S_Lno < Tlno loop
         declare
            Nxt : constant Natural := Next (SB, E);
         begin
            if SB.Cells (E).S_Lno + SB.Cells (E).Num_Lines > Tlno then
               declare
                  Len  : constant Natural := Tlno - SB.Cells (E).S_Lno;
                  Susp : constant Natural := SB.Cells (E).Suspect;
                  N    : constant Natural := Split_Blame_At (SB, E, Len, Susp);
               begin
                  Set_Next (SB, N, Diffp);
                  Diffp := N;
               end;
            end if;
            SB.Cells.Reference (E).Suspect := Parent;
            SB.Cells.Reference (E).S_Lno := SB.Cells (E).S_Lno + Offset;
            Set_Next (SB, E, Samep);
            Samep := E;
            E := Nxt;
         end;
      end loop;

      if Samep /= 0 then
         Set_Next (SB, Dstq, Reverse_Blame (SB, Samep, Next (SB, Dstq)));
         Dstq := Samep;
      end if;
      E := Reverse_Blame (SB, Diffp, E);

      Samep := 0;
      Diffp := 0;

      declare
         N_Lines     : constant Natural :=
           (if Ignore_Diffs and then Same - Tlno > 0 then Same - Tlno else 0);
         Line_Blames : Tracker_Array (0 .. Natural'Max (N_Lines, 1) - 1);
      begin
         if N_Lines > 0 then
            Guess_Line_Blames
              (SB, Parent, Target, Tlno, Offset, Same, Parent_Len, Line_Blames);
         end if;

         while E /= 0 and then SB.Cells (E).S_Lno < Same loop
            declare
               Nxt : constant Natural := Next (SB, E);
            begin
               if SB.Cells (E).S_Lno + SB.Cells (E).Num_Lines > Same then
                  declare
                     Len  : constant Natural := Same - SB.Cells (E).S_Lno;
                     Susp : constant Natural := SB.Cells (E).Suspect;
                     N    : constant Natural := Split_Blame_At (SB, E, Len, Susp);
                  begin
                     Set_Next (SB, N, Samep);
                     Samep := N;
                  end;
               end if;
               if Ignore_Diffs then
                  declare
                     Base : constant Natural := SB.Cells (E).S_Lno - Tlno;
                  begin
                     Ignore_Blame_Entry
                       (SB, E, Parent, Diffp, Ignoredp, Line_Blames, Base);
                  end;
               else
                  Set_Next (SB, E, Diffp);
                  Diffp := E;
               end if;
               E := Nxt;
            end;
         end loop;
      end;

      if Ignoredp /= 0 then
         Set_Next (SB, Dstq, Reverse_Blame (SB, Ignoredp, Next (SB, Dstq)));
         Dstq := Ignoredp;
      end if;
      Set_Next
        (SB, Srcq, Reverse_Blame (SB, Diffp, Reverse_Blame (SB, Samep, E)));
      if Diffp /= 0 then
         Srcq := Diffp;
      end if;
   end Blame_Chunk;

   --  git's pass_blame_to_parent.
   procedure Pass_Blame_To_Parent
     (SB : in out Scoreboard; Target, Parent : Natural; Ignore_Diffs : Boolean)
   is
      Newdest : Natural;
      Dstq    : Natural;
      Srcq    : Natural;
      Offset  : Integer := 0;
   begin
      if Suspects (SB, Target) = 0 then
         return;
      end if;
      Newdest := New_Cell (SB);
      Dstq := Newdest;
      Srcq := SB.Origins (Target).Suspects;

      Fill_Origin_Blob (SB, Parent, Ignore_Diffs);
      Fill_Origin_Blob (SB, Target, Ignore_Diffs);
      SB.Num_Get_Patch := SB.Num_Get_Patch + 1;

      declare
         Changes : constant Version.Merge.Text_Change_Vectors.Vector :=
           Changes_Between
             (SB, To_String (SB.Origins (Parent).File),
              To_String (SB.Origins (Target).File));
      begin
         for Ch of Changes loop
            declare
               Start_A : constant Integer := Ch.Old_First;
               Count_A : constant Integer := Ch.Old_After - Ch.Old_First;
               Start_B : constant Integer := Ch.New_First;
               Count_B : constant Integer := Ch.New_After - Ch.New_First;
            begin
               Blame_Chunk
                 (SB, Dstq, Srcq, Start_B, Start_A - Start_B,
                  Start_B + Count_B, Count_A, Parent, Target, Ignore_Diffs);
               Offset := Start_A + Count_A - (Start_B + Count_B);
            end;
         end loop;
      end;
      Blame_Chunk
        (SB, Dstq, Srcq, Integer'Last, Offset, Integer'Last, 0,
         Parent, Target, False);
      Set_Next (SB, Dstq, 0);

      declare
         List : Natural := Next (SB, Newdest);
      begin
         if Ignore_Diffs then
            List := Sort_List (SB, List, By_Suspect => True);
         end if;
         Queue_Blames (SB, Parent, List);
      end;
   end Pass_Blame_To_Parent;

   ---------------------------------------------------------------------
   --  Moves and copies (-M / -C)
   ---------------------------------------------------------------------

   --  git's handle_split.
   procedure Handle_Split
     (SB               : Scoreboard;
      Ent              : Entry_Rec;
      Tlno, Plno, Same : Integer;
      Parent           : Natural;
      Split            : in out Split_Array)
   is
   begin
      if Ent.Num_Lines <= Tlno then
         return;
      end if;
      if Tlno < Same then
         declare
            Potential : Split_Array;
         begin
            Split_Overlap
              (Potential, Ent, Tlno + Ent.S_Lno, Plno, Same + Ent.S_Lno, Parent);
            Copy_Split_If_Better (SB, Split, Potential);
         end;
      end if;
   end Handle_Split;

   --  git's find_copy_in_blob: the best run of Ent's lines found in the
   --  parent's file.
   procedure Find_Copy_In_Blob
     (SB     : Scoreboard;
      Ent    : Entry_Rec;
      Parent : Natural;
      Split  : out Split_Array;
      File_P : String)
   is
      Plno : Integer := 0;
      Tlno : Integer := 0;
      Changes : constant Version.Merge.Text_Change_Vectors.Vector :=
        Changes_Between
          (SB, File_P, Final_Slice (SB, Ent.Lno, Ent.Lno + Ent.Num_Lines));
   begin
      Split := [others => (others => <>)];
      for Ch of Changes loop
         Handle_Split (SB, Ent, Tlno, Plno, Ch.New_First, Parent, Split);
         Plno := Ch.Old_After;
         Tlno := Ch.New_After;
      end loop;
      Handle_Split (SB, Ent, Tlno, Plno, Ent.Num_Lines, Parent, Split);
   end Find_Copy_In_Blob;

   --  git's filter_small: move the entries scoring at most Score_Min from
   --  the list at slot Source to the front of the list at slot Small,
   --  which advances past them.
   procedure Filter_Small
     (SB        : in out Scoreboard;
      Small     : in out Natural;
      Source_In : Natural;
      Score_Min : Natural)
   is
      Source   : Natural := Source_In;
      P        : Natural := Next (SB, Source);
      Oldsmall : constant Natural := Next (SB, Small);
   begin
      while P /= 0 loop
         if Cell_Score (SB, P) <= Score_Min then
            Set_Next (SB, Small, P);
            Small := P;
         else
            Set_Next (SB, Source, P);
            Source := P;
         end if;
         P := Next (SB, P);
      end loop;
      Set_Next (SB, Small, Oldsmall);
      Set_Next (SB, Source, 0);
   end Filter_Small;

   --  git's find_move_in_parent.
   procedure Find_Move_In_Parent
     (SB             : in out Scoreboard;
      Blamed         : in out Natural;
      Toosmall_In    : Natural;
      Target, Parent : Natural)
   is
      --  The caller's slot is where the small entries go; git advances a
      --  local copy past them, so each call prepends its own.
      Toosmall : Natural := Toosmall_In;
      U        : Natural;   --  unblamed head cell
      Leftover : Natural := 0;
   begin
      if Suspects (SB, Target) = 0 then
         return;
      end if;
      U := New_Cell (SB);
      Set_Next (SB, U, Suspects (SB, Target));
      Fill_Origin_Blob (SB, Parent, False);
      declare
         File_P : constant String := To_String (SB.Origins (Parent).File);
      begin
         loop
            declare
               Unblamedtail : Natural := U;
               E            : Natural := Next (SB, U);
            begin
               while E /= 0 loop
                  declare
                     Nxt   : constant Natural := Next (SB, E);
                     Split : Split_Array;
                  begin
                     Find_Copy_In_Blob (SB, SB.Cells (E), Parent, Split, File_P);
                     if Split (1).Suspect /= 0
                       and then SB.Opts.Move_Score < Entry_Score (SB, Split (1))
                     then
                        Split_Blame (SB, Blamed, Unblamedtail, Split, E);
                     else
                        Set_Next (SB, E, Leftover);
                        Leftover := E;
                     end if;
                     E := Nxt;
                  end;
               end loop;
               Set_Next (SB, Unblamedtail, 0);
            end;
            Filter_Small (SB, Toosmall, U, SB.Opts.Move_Score);
            exit when Next (SB, U) = 0;
         end loop;
      end;
      Set_Next (SB, SB.Origins (Target).Suspects, Reverse_Blame (SB, Leftover, 0));
   end Find_Move_In_Parent;

   --  git's find_copy_in_parent: try the other paths the parent had.
   procedure Find_Copy_In_Parent
     (SB          : in out Scoreboard;
      Blamed      : in out Natural;
      Toosmall_In : Natural;
      Target      : Natural;
      Parent      : Natural;
      Porigin     : Natural)
   is
      Toosmall   : Natural := Toosmall_In;
      U          : Natural;
      Leftover   : Natural := 0;
      Harder     : constant Boolean :=
        SB.Opts.Copies >= 3
        or else (SB.Opts.Copies >= 2
                 and then (Porigin = 0
                           or else SB.Origins (Target).Path
                                   /= SB.Origins (Porigin).Path));
      Candidates : Version.Objects.Tree_Entry_Vectors.Vector;
   begin
      if Suspects (SB, Target) = 0 then
         return;
      end if;
      U := New_Cell (SB);
      Set_Next (SB, U, Suspects (SB, Target));

      --  The parent-side files of the parent -> target diff (every file
      --  when finding copies harder), gitlinks and the path find_move
      --  already tried left out.
      declare
         PFlat : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Flat_Blobs (SB, Parent);
         TFlat : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Flat_Blobs (SB, SB.Origins (Target).Commit);
      begin
         for E of PFlat loop
            if E.Kind /= Version.Objects.Tree_Gitlink
              and then not (Porigin /= 0
                            and then E.Path = SB.Origins (Porigin).Path)
            then
               if Harder then
                  Candidates.Append (E);
               else
                  declare
                     K : constant Natural := Find_Flat (TFlat, To_String (E.Path));
                  begin
                     if K = 0
                       or else TFlat (K - 1).Id /= E.Id
                       or else TFlat (K - 1).Mode /= E.Mode
                     then
                        Candidates.Append (E);
                     end if;
                  end;
               end if;
            end if;
         end loop;
      end;

      loop
         declare
            Unblamedtail : Natural := U;
            Ents         : Nat_Vectors.Vector;
            E            : Natural := Next (SB, U);
         begin
            while E /= 0 loop
               Ents.Append (E);
               E := Next (SB, E);
            end loop;
            declare
               Splits : array (1 .. Natural (Ents.Length)) of Split_Array :=
                 [others => [others => (others => <>)]];
            begin
               for Cand of Candidates loop
                  declare
                     Norigin : constant Natural :=
                       Get_Origin (SB, Parent, To_String (Cand.Path));
                  begin
                     SB.Origins.Reference (Norigin).Blob := Cand.Id;
                     SB.Origins.Reference (Norigin).Mode := Cand.Mode;
                     Fill_Origin_Blob (SB, Norigin, False);
                     declare
                        File_P : constant String :=
                          To_String (SB.Origins (Norigin).File);
                     begin
                        for J in 1 .. Natural (Ents.Length) loop
                           declare
                              Potential : Split_Array;
                           begin
                              Find_Copy_In_Blob
                                (SB, SB.Cells (Ents (J)), Norigin, Potential, File_P);
                              Copy_Split_If_Better (SB, Splits (J), Potential);
                           end;
                        end loop;
                     end;
                  end;
               end loop;

               for J in 1 .. Natural (Ents.Length) loop
                  if Splits (J) (1).Suspect /= 0
                    and then SB.Opts.Copy_Score < Entry_Score (SB, Splits (J) (1))
                  then
                     Split_Blame (SB, Blamed, Unblamedtail, Splits (J), Ents (J));
                  else
                     Set_Next (SB, Ents (J), Leftover);
                     Leftover := Ents (J);
                  end if;
               end loop;
            end;
            Set_Next (SB, Unblamedtail, 0);
         end;
         Filter_Small (SB, Toosmall, U, SB.Opts.Copy_Score);
         exit when Next (SB, U) = 0;
      end loop;
      Set_Next (SB, SB.Origins (Target).Suspects, Reverse_Blame (SB, Leftover, 0));
   end Find_Copy_In_Parent;

   ---------------------------------------------------------------------
   --  Finding the file in a parent
   ---------------------------------------------------------------------

   --  git's find_origin: the same path in the parent, when it is there
   --  with the same file type.
   function Find_Origin
     (SB : in out Scoreboard; Parent, Origin : Natural) return Natural
   is
      Path  : constant String := To_String (SB.Origins (Origin).Path);
      O     : Natural := SB.Commits (Parent).Origins;
      Found : Boolean;
      Id    : Version.Objects.Object_Id_Storage;
      Mode  : Unbounded_String;
      Kind  : Version.Objects.Tree_Entry_Kind;
   begin
      while O /= 0 loop
         if To_String (SB.Origins (O).Path) = Path then
            return O;
         end if;
         O := SB.Origins (O).Next;
      end loop;

      Lookup_Path (SB, Parent, Path, Found, Id, Mode, Kind);
      if not Found or else Kind = Version.Objects.Tree_Directory then
         return 0;
      end if;
      if Type_Bits (To_String (Mode))
           /= Type_Bits (To_String (SB.Origins (Origin).Mode))
      then
         return 0;
      end if;
      declare
         PO : constant Natural := Get_Origin (SB, Parent, Path);
      begin
         SB.Origins.Reference (PO).Blob := Id;
         SB.Origins.Reference (PO).Mode := Mode;
         return PO;
      end;
   end Find_Origin;

   --  git's find_rename: the path the parent had the file under, by
   --  rename detection of the parent -> commit diff towards this path.
   function Find_Rename
     (SB : in out Scoreboard; Parent, Origin : Natural) return Natural
   is
      Path  : constant String := To_String (SB.Origins (Origin).Path);
      PFlat : constant Version.Objects.Tree_Entry_Vectors.Vector :=
        Flat_Blobs (SB, Parent);
      OFlat : constant Version.Objects.Tree_Entry_Vectors.Vector :=
        Flat_Blobs (SB, SB.Origins (Origin).Commit);
      Sources, Dests : Version.Rename_Detect.Side_Vectors.Vector;

      function Content_Of
        (Side : Version.Rename_Detect.Rename_Side) return String
      is (Read_Blob (SB, Side.Id));

      function Detect is new Version.Rename_Detect.Detect (Content_Of);
   begin
      if Find_Flat (PFlat, Path) /= 0 then
         return 0;
      end if;
      for E of PFlat loop
         if Find_Flat (OFlat, To_String (E.Path)) = 0 then
            Sources.Append
              (Version.Rename_Detect.Rename_Side'
                 (Path => E.Path, Id => E.Id, Mode => E.Mode));
         end if;
      end loop;
      if Sources.Is_Empty then
         return 0;
      end if;
      Dests.Append
        (Version.Rename_Detect.Rename_Side'
           (Path => To_Unbounded_String (Path),
            Id   => SB.Origins (Origin).Blob,
            Mode => SB.Origins (Origin).Mode));
      declare
         Pairs : constant Version.Rename_Detect.Pair_Vectors.Vector :=
           Detect (Sources, Dests);
      begin
         for P of Pairs loop
            if P.Dest = Dests.First_Index then
               declare
                  S  : constant Version.Rename_Detect.Rename_Side :=
                    Sources (P.Source);
                  PO : constant Natural :=
                    Get_Origin (SB, Parent, To_String (S.Path));
               begin
                  SB.Origins.Reference (PO).Blob := S.Id;
                  SB.Origins.Reference (PO).Mode := S.Mode;
                  return PO;
               end;
            end if;
         end loop;
      end;
      return 0;
   end Find_Rename;

   --  git's pass_whole_blame: identical blobs, so everything moves.
   procedure Pass_Whole_Blame (SB : in out Scoreboard; Origin, PO : Natural) is
      Head : constant Natural := SB.Origins (Origin).Suspects;
      List : constant Natural := Next (SB, Head);
      E    : Natural := List;
   begin
      if not SB.Origins (PO).Have_File and then SB.Origins (Origin).Have_File then
         SB.Origins.Reference (PO).File := SB.Origins (Origin).File;
         SB.Origins.Reference (PO).Have_File := True;
         SB.Origins.Reference (Origin).File := Null_Unbounded_String;
         SB.Origins.Reference (Origin).Have_File := False;
      end if;
      Set_Next (SB, Head, 0);
      while E /= 0 loop
         SB.Cells.Reference (E).Suspect := PO;
         E := Next (SB, E);
      end loop;
      Queue_Blames (SB, PO, List);
   end Pass_Whole_Blame;

   --  git's pass_blame: exonerate this origin as far as its scapegoats
   --  allow.
   procedure Pass_Blame (SB : in out Scoreboard; Origin : Natural) is
      Commit    : constant Natural := SB.Origins (Origin).Commit;
      SG        : constant Nat_Vectors.Vector := Scapegoats (SB, Commit);
      Num_SG    : constant Natural := Natural (SG.Length);
      SG_Orig   : Nat_Vectors.Vector;
      Toosmall  : Natural;   --  head cell of the too-small list
      Blames    : Natural;
      Blametail : Natural;
      Passes    : constant Natural := (if SB.Opts.Follow_Renames then 2 else 1);
   begin
      Toosmall := New_Cell (SB);
      Blames := New_Cell (SB);
      Blametail := Blames;
      for I in 1 .. Num_SG loop
         SG_Orig.Append (0);
      end loop;

      if Num_SG > 0 then
         --  The first pass looks for the unrenamed path, the second for
         --  renames.
         for Pass in 1 .. Passes loop
            for I in 1 .. Num_SG loop
               if SG_Orig (I) = 0 then
                  declare
                     P      : constant Natural := SG (I);
                     PO     : Natural := 0;
                     Parsed : Boolean := True;
                  begin
                     begin
                        Parse_Commit (SB, P);
                     exception
                        when Ada.IO_Exceptions.Data_Error
                           | Ada.IO_Exceptions.Name_Error =>
                           Parsed := False;
                     end;
                     if Parsed then
                        PO :=
                          (if Pass = 1 then Find_Origin (SB, P, Origin)
                           else Find_Rename (SB, P, Origin));
                     end if;
                     if PO /= 0 then
                        if SB.Origins (PO).Blob = SB.Origins (Origin).Blob then
                           Pass_Whole_Blame (SB, Origin, PO);
                           goto Finish;
                        end if;
                        declare
                           Same : Boolean := False;
                        begin
                           for J in 1 .. I - 1 loop
                              if SG_Orig (J) /= 0
                                and then SB.Origins (SG_Orig (J)).Blob
                                         = SB.Origins (PO).Blob
                              then
                                 Same := True;
                                 exit;
                              end if;
                           end loop;
                           if not Same then
                              SG_Orig.Replace_Element (I, PO);
                           end if;
                        end;
                     end if;
                  end;
               end if;
            end loop;
         end loop;

         SB.Num_Commits := SB.Num_Commits + 1;
         for I in 1 .. Num_SG loop
            if SG_Orig (I) /= 0 then
               if SB.Origins (Origin).Previous = 0 then
                  SB.Origins.Reference (Origin).Previous := SG_Orig (I);
               end if;
               Pass_Blame_To_Parent (SB, Origin, SG_Orig (I), False);
               if Suspects (SB, Origin) = 0 then
                  goto Finish;
               end if;
            end if;
         end loop;

         --  Pass remaining suspects for ignored commits to their parents.
         if SB.Ignore.Contains (SB.Commits (Commit).Id) then
            for I in 1 .. Num_SG loop
               if SG_Orig (I) /= 0 then
                  Pass_Blame_To_Parent (SB, Origin, SG_Orig (I), True);
                  Drop_Origin_Blob (SB, SG_Orig (I));
                  if Suspects (SB, Origin) = 0 then
                     goto Finish;
                  end if;
               end if;
            end loop;
         end if;

         if SB.Opts.Find_Moves or else SB.Opts.Copies > 0 then
            declare
               Small : Natural := Toosmall;
            begin
               Filter_Small
                 (SB, Small, SB.Origins (Origin).Suspects, SB.Opts.Move_Score);
            end;
            if Suspects (SB, Origin) /= 0 then
               for I in 1 .. Num_SG loop
                  if SG_Orig (I) /= 0 then
                     Find_Move_In_Parent
                       (SB, Blametail, Toosmall, Origin, SG_Orig (I));
                     exit when Suspects (SB, Origin) = 0;
                  end if;
               end loop;
            end if;
         end if;

         if SB.Opts.Copies > 0 then
            declare
               Head  : constant Natural := SB.Origins (Origin).Suspects;
               Small : Natural := Toosmall;
            begin
               if SB.Opts.Copy_Score > SB.Opts.Move_Score then
                  Filter_Small (SB, Small, Head, SB.Opts.Copy_Score);
               elsif SB.Opts.Copy_Score < SB.Opts.Move_Score then
                  Set_Next
                    (SB, Head,
                     Blame_Merge (SB, Next (SB, Head), Next (SB, Toosmall)));
                  Set_Next (SB, Toosmall, 0);
                  Filter_Small (SB, Small, Head, SB.Opts.Copy_Score);
               end if;
            end;
            if Suspects (SB, Origin) = 0 then
               goto Finish;
            end if;
            for I in 1 .. Num_SG loop
               Find_Copy_In_Parent
                 (SB, Blametail, Toosmall, Origin, SG (I), SG_Orig (I));
               if Suspects (SB, Origin) = 0 then
                  goto Finish;
               end if;
            end loop;
         end if;
      end if;

      <<Finish>>
      Set_Next (SB, Blametail, 0);
      Distribute_Blame (SB, Next (SB, Blames));

      --  The entries too small to chase go back in front of the suspects.
      declare
         Head : constant Natural := SB.Origins (Origin).Suspects;
         T    : Natural := Next (SB, Toosmall);
      begin
         if T /= 0 then
            while Next (SB, T) /= 0 loop
               T := Next (SB, T);
            end loop;
            Set_Next (SB, T, Next (SB, Head));
            Set_Next (SB, Head, Next (SB, Toosmall));
         end if;
      end;

      for I in 1 .. Num_SG loop
         if SG_Orig (I) /= 0 and then Suspects (SB, SG_Orig (I)) = 0 then
            Drop_Origin_Blob (SB, SG_Orig (I));
         end if;
      end loop;
      Drop_Origin_Blob (SB, Origin);
   end Pass_Blame;

   --  git's assign_blame: the main loop.
   procedure Assign_Blame (SB : in out Scoreboard) is
      Commit : Natural := Queue_Get (SB);
   begin
      while Commit /= 0 loop
         declare
            Suspect : Natural := SB.Commits (Commit).Origins;
         begin
            while Suspect /= 0 and then Suspects (SB, Suspect) = 0 loop
               Suspect := SB.Origins (Suspect).Next;
            end loop;

            if Suspect = 0 then
               Commit := Queue_Get (SB);
            else
               Parse_Commit (SB, Commit);
               if SB.Opts.Reverse_Blame
                 or else (not Is_Uninteresting (SB, Commit)
                          and then not (SB.Opts.Max_Age /= -1
                                        and then SB.Commits (Commit).Date
                                                 < SB.Opts.Max_Age))
               then
                  Pass_Blame (SB, Suspect);
               else
                  SB.Commits.Reference (Commit).Uninteresting := True;
                  Mark_Parents_Uninteresting (SB, Commit);
               end if;
               --  A root commit is a boundary unless --root.
               if SB.Commits (Commit).Parents.Is_Empty
                 and then not SB.Opts.Show_Root
               then
                  SB.Commits.Reference (Commit).Uninteresting := True;
               end if;

               --  Take responsibility for the remaining entries.
               declare
                  Head : constant Natural := SB.Origins (Suspect).Suspects;
                  E    : Natural := Next (SB, Head);
               begin
                  if E /= 0 then
                     SB.Origins.Reference (Suspect).Guilty := True;
                     loop
                        SB.Found.Append
                          (Found_Rec'(Origin     => Suspect,
                                      Lno        => SB.Cells (E).Lno,
                                      S_Lno      => SB.Cells (E).S_Lno,
                                      Num_Lines  => SB.Cells (E).Num_Lines,
                                      Ignored    => SB.Cells (E).Ignored,
                                      Unblamable => SB.Cells (E).Unblamable));
                        exit when Next (SB, E) = 0;
                        E := Next (SB, E);
                     end loop;
                     Set_Next (SB, E, SB.Ent);
                     SB.Ent := Next (SB, Head);
                     Set_Next (SB, Head, 0);
                  end if;
               end;
            end if;
         end;
      end loop;
   end Assign_Blame;

   ---------------------------------------------------------------------
   --  Setting up: the fake working-tree commit and -L
   ---------------------------------------------------------------------

   function Readlink
     (Path   : System.Address;
      Buf    : System.Address;
      Bufsiz : Interfaces.C.size_t) return Integer;
   pragma Import (C, Readlink, "__gnat_readlink");

   function Symlink_Target (Path : String) return String is
      C_Path : aliased String := Path & Character'Val (0);
      Buffer : aliased String (1 .. 8192);
      Count  : constant Integer :=
        Readlink
          (Path   => C_Path (C_Path'First)'Address,
           Buf    => Buffer (Buffer'First)'Address,
           Bufsiz => Interfaces.C.size_t (Buffer'Length));
   begin
      if Count < 0 then
         raise Blame_Error with "cannot readlink '" & Path & "'";
      end if;
      return Buffer (1 .. Count);
   end Symlink_Target;

   --  git's fake_working_tree_commit: a commit on top of Parent_Id (and
   --  MERGE_HEAD) whose copy of Path is the working file or --contents.
   function Fake_Working_Tree_Commit
     (SB        : in out Scoreboard;
      Path      : String;
      Parent_Id : Version.Objects.Object_Id_Storage)
      return Natural
   is
      C       : Natural;
      Content : Unbounded_String;
      Mode    : Unbounded_String;
   begin
      SB.Commits.Append
        (Commit_Rec'(Is_Fake => True, Parsed => True,
                     Date    => Version.Timestamps.Unix_Now,
                     others  => <>));
      C := SB.Commits.Last_Index;
      SB.Has_Fake := True;
      SB.Fake_Time := SB.Commits (C).Date;

      declare
         PI : constant Natural := Lookup_Commit (SB, Parent_Id);
      begin
         SB.Commits.Reference (C).Parents.Append (PI);
      end;
      declare
         MH : constant String :=
           Version.Files.Join (Version.Repository.Git_Dir (SB.Repo), "MERGE_HEAD");
      begin
         if Ada.Directories.Exists (MH) then
            declare
               Text  : constant String := Version.Files.Read_Binary_File (MH);
               Start : Positive := Text'First;
            begin
               for K in Text'Range loop
                  if Text (K) = LF then
                     declare
                        Line : constant String := Text (Start .. K - 1);
                     begin
                        if not Version.Objects.Is_Valid_Hex_Object_Id (Line) then
                           raise Blame_Error with
                             "unknown line in '" & MH & "': " & Line;
                        end if;
                        declare
                           PI : constant Natural :=
                             Lookup_Commit (SB, Version.Objects.To_Object_Id (Line));
                        begin
                           SB.Commits.Reference (C).Parents.Append (PI);
                        end;
                     end;
                     Start := K + 1;
                  end if;
               end loop;
            end;
         end if;
      end;

      SB.Fake_Index := Version.Staging.Load (SB.Repo);

      --  verify_working_tree_path: one of the parents has the blob, or the
      --  index has the path.
      declare
         OK      : Boolean := False;
         Parents : constant Nat_Vectors.Vector := SB.Commits (C).Parents;
      begin
         for P of Parents loop
            declare
               Found : Boolean;
               Id    : Version.Objects.Object_Id_Storage;
               PMode : Unbounded_String;
               Kind  : Version.Objects.Tree_Entry_Kind;
            begin
               Lookup_Path (SB, P, Path, Found, Id, PMode, Kind);
               if Found and then Kind = Version.Objects.Tree_Blob then
                  OK := True;
                  exit;
               end if;
            end;
         end loop;
         if not OK then
            for E of SB.Fake_Index loop
               if To_String (E.Path) = Path then
                  OK := True;
                  exit;
               end if;
            end loop;
         end if;
         if not OK then
            raise Blame_Error with "no such path '" & Path & "' in HEAD";
         end if;
      end;

      if SB.Opts.Have_Contents then
         Content := SB.Opts.Contents;
         Mode := Null_Unbounded_String;
      else
         declare
            Full : constant String :=
              Version.Files.To_Native_Path
                (Version.Files.Join (Version.Repository.Root_Path (SB.Repo), Path));
         begin
            if GNAT.OS_Lib.Is_Symbolic_Link (Full) then
               Content := To_Unbounded_String (Symlink_Target (Full));
               Mode := To_Unbounded_String ("120000");
            elsif GNAT.OS_Lib.Is_Regular_File (Full) then
               Content :=
                 To_Unbounded_String (Version.Files.Read_Binary_File (Full));
               Mode := To_Unbounded_String
                 (if Version.Platform.Supports_Executable_Bit
                    and then GNAT.OS_Lib.Is_Executable_File (Full)
                  then "100755" else "100644");
               if SB.Opts.Textconv then
                  declare
                     Cmd : constant String :=
                       Version.Diff.Textconv_Command (SB.Repo, Path);
                  begin
                     if Cmd /= "" then
                        Content := To_Unbounded_String
                          (Version.Diff.Run_Textconv (Cmd, To_String (Content)));
                     end if;
                  end;
               end if;
            elsif GNAT.OS_Lib.Is_Directory (Full) then
               raise Blame_Error with "unsupported file type " & Path;
            else
               raise Blame_Error with
                 "Cannot lstat '" & Path & "': No such file or directory";
            end if;
         end;
      end if;

      --  convert_to_git
      Content := To_Unbounded_String
        (Version.Text_Filter.Clean_Content (SB.Repo, Path, To_String (Content)));

      if Length (Mode) = 0 then
         Mode := To_Unbounded_String ("100644");
         for E of SB.Fake_Index loop
            if To_String (E.Path) = Path and then E.Stage = 0 then
               Mode := E.Mode;
               exit;
            end if;
         end loop;
      end if;

      declare
         O     : constant Natural := Make_Origin (SB, C, Path);
         Blob  : constant Version.Objects.Object_Id_Storage :=
           Version.Objects.Compute_Object_Id
             (Version.Repository.Algorithm (SB.Repo), "blob", To_String (Content));
         Fresh : Version.Staging.Index_Entry_Vectors.Vector;
      begin
         SB.Origins.Reference (O).File := Content;
         SB.Origins.Reference (O).Have_File := True;
         SB.Origins.Reference (O).Blob := Blob;
         SB.Origins.Reference (O).Mode := Mode;
         if not SB.Pretend.Contains (Blob) then
            SB.Pretend.Insert (Blob, Content);
         end if;

         --  The index with Path replaced by the fake blob (its mode kept),
         --  which is what "diff-index --cached" against a parent sees.
         for E of SB.Fake_Index loop
            if To_String (E.Path) /= Path then
               Fresh.Append (E);
            end if;
         end loop;
         Fresh.Append
           (Version.Staging.Index_Entry'
              (Path => To_Unbounded_String (Path), Id => Blob, Mode => Mode,
               others => <>));
         Version.Staging.Sort_By_Path (Fresh);
         SB.Fake_Index := Fresh;
      end;
      return C;
   end Fake_Working_Tree_Commit;

   --  Line Lno (0-based) of the final image without its newline; "" past
   --  the end.
   function Final_Line (SB : Scoreboard; Lno : Natural) return String is
   begin
      if Lno >= SB.Num_Lines then
         return "";
      end if;
      declare
         From : constant Natural := SB.Line_Starts (Lno);
         To   : Natural := SB.Line_Starts (Lno + 1);
      begin
         if To > From and then Element (SB.Final_Text, To) = LF then
            To := To - 1;
         end if;
         return Slice (SB.Final_Text, From + 1, To);
      end;
   end Final_Line;

   --  xdiff's default funcname rule: a line starting a letter, `_` or `$`.
   function Is_Funcname_Line (L : String) return Boolean is
     (L'Length > 0
      and then L (L'First) in 'a' .. 'z' | 'A' .. 'Z' | '_' | '$');

   --  git's parse_range_arg (line-range.c) for one -L spec, against the
   --  final image; Bottom/Top are 1-based (0 = unset).
   procedure Parse_Range_Arg
     (SB        : Scoreboard;
      Arg       : String;
      Anchor_In : Integer;
      Bottom    : out Integer;
      Top       : out Integer)
   is
      Lines  : constant Integer := SB.Num_Lines;
      Anchor : Integer := Anchor_In;

      function Compile_Or_Die
        (Pattern, Context : String) return Version.Grep.Line_Matcher is
      begin
         return Version.Grep.Compile
           (Pattern, (Kind => Version.Grep.Basic_Regex, others => <>));
      exception
         when Ada.IO_Exceptions.Data_Error =>
            raise Blame_Error with Context & "Invalid regular expression";
      end Compile_Or_Die;

      --  parse_loc: one end of the range; returns the index after what it
      --  consumed.  Begin_L is minus the anchor for the start of a range,
      --  and the line after the start for its end.
      function Parse_Loc
        (Spec    : String;
         Begin_L : Integer;
         Ret     : out Integer)
         return Natural
      is
         P     : Natural := Spec'First;
         Start : Integer := Begin_L;
      begin
         Ret := 0;
         if Spec'Length = 0 then
            return Spec'First;
         end if;

         --  "+N" / "-N" relative to the start.
         if 1 <= Start and then (Spec (P) = '+' or else Spec (P) = '-') then
            declare
               Q   : Natural := P + 1;
               Num : Integer := 0;
            begin
               while Q <= Spec'Last and then Spec (Q) in '0' .. '9' loop
                  Num := Num * 10 + Character'Pos (Spec (Q)) - Character'Pos ('0');
                  Q := Q + 1;
               end loop;
               if Q > P + 1 then
                  if Num = 0 then
                     raise Blame_Error with "-L invalid empty range";
                  end if;
                  if Spec (P) = '-' then
                     Num := -Num;
                  end if;
                  if Num > 0 then
                     Ret := Start + Num - 2;
                  else
                     Ret := (if Start + Num > 0 then Start + Num else 1);
                  end if;
                  return Q;
               end if;
               return P;
            end;
         end if;

         --  A plain number.
         declare
            Q   : Natural := P;
            Neg : Boolean := False;
            Num : Integer := 0;
         begin
            if Spec (Q) = '-' or else Spec (Q) = '+' then
               Neg := Spec (Q) = '-';
               Q := Q + 1;
            end if;
            declare
               Digits_At : constant Natural := Q;
            begin
               while Q <= Spec'Last and then Spec (Q) in '0' .. '9' loop
                  Num := Num * 10 + Character'Pos (Spec (Q)) - Character'Pos ('0');
                  Q := Q + 1;
               end loop;
               if Q > Digits_At then
                  if Neg then
                     Num := -Num;
                  end if;
                  if Num <= 0 then
                     raise Blame_Error with
                       "-L invalid line number: " & Img (Num);
                  end if;
                  Ret := Num;
                  return Q;
               end if;
            end;
         end;

         if Start < 0 then
            if Spec (P) /= '^' then
               Start := -Start;
            else
               Start := 1;
               P := P + 1;
            end if;
         end if;

         if P > Spec'Last or else Spec (P) /= '/' then
            return P;
         end if;

         --  /regex/
         declare
            Term : Natural := P + 1;
         begin
            while Term <= Spec'Last and then Spec (Term) /= '/' loop
               if Spec (Term) = '\' then
                  Term := Term + 1;
               end if;
               Term := Term + 1;
            end loop;
            if Term > Spec'Last then
               return P;
            end if;
            declare
               Pattern : constant String := Spec (P + 1 .. Term - 1);
               Line0   : constant Integer := Start - 1;
               M       : constant Version.Grep.Line_Matcher :=
                 Compile_Or_Die
                   (Pattern,
                    "-L parameter '" & Pattern & "' starting at line "
                    & Img (Line0 + 1) & ": ");
            begin
               for K in Line0 .. Integer'Max (Line0, Lines - 1) loop
                  if K < Lines
                    and then Version.Grep.Matches (M, Final_Line (SB, K))
                  then
                     Ret := K + 1;
                     return Term + 1;
                  end if;
               end loop;
               --  The regex may still match the empty tail.
               if Version.Grep.Matches (M, "") then
                  Ret := Integer'Max (Line0, Lines) + 1;
                  return Term + 1;
               end if;
               raise Blame_Error with
                 "-L parameter '" & Pattern & "' starting at line "
                 & Img (Line0 + 1) & ": No match";
            end;
         end;
      end Parse_Loc;

      --  parse_range_funcname: ":<regex>" names the function whose
      --  header line matches, through to the line before the next header.
      procedure Parse_Range_Funcname (Spec : String) is
         P    : Natural := Spec'First;
         Anch : Integer := Anchor;
      begin
         if Spec (P) = '^' then
            Anch := 1;
            P := P + 1;
         end if;
         P := P + 1;   --  the ':'
         declare
            Term : Natural := P;
         begin
            while Term <= Spec'Last and then Spec (Term) /= ':' loop
               if Spec (Term) = '\' and then Term < Spec'Last then
                  Term := Term + 1;
               end if;
               Term := Term + 1;
            end loop;
            --  An empty pattern, or text after a closing ':'.
            if Term = P or else Term <= Spec'Last then
               raise Range_Error;
            end if;
            declare
               Pattern : constant String := Spec (P .. Term - 1);
               M       : constant Version.Grep.Line_Matcher :=
                 Compile_Or_Die (Pattern, "-L parameter '" & Pattern & "': ");
               Found   : Integer := -1;
            begin
               for K in Anch - 1 .. Integer'Max (Anch - 1, Lines - 1) loop
                  if K < Lines then
                     declare
                        L : constant String := Final_Line (SB, K);
                     begin
                        if Version.Grep.Matches (M, L)
                          and then Is_Funcname_Line (L)
                        then
                           Found := K;
                           exit;
                        end if;
                     end;
                  end if;
               end loop;
               if Found < 0 then
                  raise Blame_Error with
                    "-L parameter '" & Pattern & "' starting at line "
                    & Img (Anch) & ": no match";
               end if;
               Bottom := Found;
               Top := Found + 1;
               while Top < Lines loop
                  exit when Is_Funcname_Line (Final_Line (SB, Top));
                  Top := Top + 1;
               end loop;
               Bottom := Bottom + 1;
            end;
         end;
      end Parse_Range_Funcname;
   begin
      Bottom := 0;
      Top := 0;
      if Anchor < 1 then
         Anchor := 1;
      end if;
      if Anchor > Lines then
         Anchor := Lines + 1;
      end if;

      if Arg'Length > 0
        and then (Arg (Arg'First) = ':'
                  or else (Arg (Arg'First) = '^' and then Arg'Length > 1
                           and then Arg (Arg'First + 1) = ':'))
      then
         Parse_Range_Funcname (Arg);
         return;
      end if;

      declare
         After : Natural := Parse_Loc (Arg, -Anchor, Bottom);
      begin
         if After <= Arg'Last and then Arg (After) = ',' then
            After := Parse_Loc (Arg (After + 1 .. Arg'Last), Bottom + 1, Top);
         end if;
         if After <= Arg'Last then
            raise Range_Error;
         end if;
      end;

      if Bottom /= 0 and then Top /= 0 and then Top < Bottom then
         declare
            T : constant Integer := Top;
         begin
            Top := Bottom;
            Bottom := T;
         end;
      end if;
   end Parse_Range_Arg;

   ---------------------------------------------------------------------
   --  Blame
   ---------------------------------------------------------------------

   function Blame
     (Repo          : Version.Repository.Repository_Handle;
      Path          : String;
      Include       : Version.History.Commit_Id_Vectors.Vector;
      Exclude       : Version.History.Commit_Id_Vectors.Vector;
      Include_Names : String_Vectors.Vector;
      Exclude_Names : String_Vectors.Vector;
      Options       : Blame_Options := (others => <>))
      return Blame_Result
   is
      SB         : Scoreboard;
      Tips       : Version.History.Commit_Id_Vectors.Vector := Include;
      Tip_Names  : String_Vectors.Vector := Include_Names;
      Bottoms    : Version.History.Commit_Id_Vectors.Vector := Exclude;
      Final_Name : Unbounded_String;
      Final_Orig : Natural := 0;
      Latest     : Natural := 0;   --  --reverse --first-parent's tip
      Result     : Blame_Result;
   begin
      SB.Repo := Repo;
      SB.Opts := Options;
      SB.Path := To_Unbounded_String (Path);
      for Id of Options.Ignore_Revs loop
         SB.Ignore.Include (Id);
      end loop;

      if Options.Reverse_Blame and then Options.Have_Contents then
         raise Blame_Error with "--contents and --reverse do not blend well.";
      end if;

      --  find_single_final / find_single_initial
      if not Options.Reverse_Blame then
         for I in Tips.First_Index .. Tips.Last_Index loop
            if SB.Final /= 0 then
               raise Blame_Error with
                 "More than one commit to dig from "
                 & Tip_Names (I - Tips.First_Index + 1) & " and "
                 & To_String (Final_Name) & "?";
            end if;
            SB.Final := Lookup_Commit (SB, Tips (I));
            Final_Name :=
              To_Unbounded_String (Tip_Names (I - Tips.First_Index + 1));
         end loop;
      else
         for I in Bottoms.First_Index .. Bottoms.Last_Index loop
            if SB.Final /= 0 then
               raise Blame_Error with
                 "More than one commit to dig up from, "
                 & Exclude_Names (I - Bottoms.First_Index + 1) & " and "
                 & To_String (Final_Name) & "?";
            end if;
            SB.Final := Lookup_Commit (SB, Bottoms (I));
            Final_Name :=
              To_Unbounded_String (Exclude_Names (I - Bottoms.First_Index + 1));
         end loop;
         if SB.Final = 0 then
            --  DWIM "--reverse ONE -- PATH" as "ONE..HEAD".
            declare
               Head : constant String := Version.Refs.Current_Commit_Id (Repo);
            begin
               if Natural (Tips.Length) = 1 and then Head /= "" then
                  SB.Final := Lookup_Commit (SB, Tips.First_Element);
                  Final_Name := To_Unbounded_String (Tip_Names.First_Element);
                  Bottoms.Append (Tips.First_Element);
                  Tips.Clear;
                  Tip_Names.Clear;
                  Tips.Append (Version.Objects.To_Object_Id (Head));
                  Tip_Names.Append ("HEAD");
               end if;
            end;
         end if;
         if SB.Final = 0 then
            raise Blame_Error with "No commit to dig up from?";
         end if;
      end if;

      --  The fake commit for the working file / --contents.
      if Options.Have_Contents or else SB.Final = 0 then
         declare
            Parent_Id : Version.Objects.Object_Id_Storage;
         begin
            if SB.Final /= 0 then
               Parent_Id := SB.Commits (SB.Final).Id;
            else
               declare
                  Head : constant String := Version.Refs.Current_Commit_Id (Repo);
               begin
                  if Head = "" then
                     raise Blame_Error with "no such ref: HEAD";
                  end if;
                  Parent_Id := Version.Objects.To_Object_Id (Head);
               end;
            end if;
            SB.Final := Fake_Working_Tree_Commit (SB, Path, Parent_Id);
            Final_Name := To_Unbounded_String (":");
         end;
      end if;

      if Options.Reverse_Blame and then Options.First_Parent then
         for T of Tips loop
            Latest := Lookup_Commit (SB, T);
         end loop;
         if Latest = 0 then
            raise Blame_Error with
              "--reverse and --first-parent together require specified latest commit";
         end if;
      end if;

      --  prepare_revision_walk: which commits are interesting, and the
      --  children map for --reverse.
      if not Bottoms.Is_Empty then
         declare
            Walk_Tips : Version.History.Commit_Id_Vectors.Vector;
         begin
            if SB.Commits (SB.Final).Is_Fake then
               for P of SB.Commits (SB.Final).Parents loop
                  Walk_Tips.Append (SB.Commits (P).Id);
               end loop;
            else
               Walk_Tips := Tips;
            end if;
            declare
               Listed : constant Version.History.Commit_Id_Vectors.Vector :=
                 Version.History.Rev_List
                   (Repo, Walk_Tips, Bottoms,
                    (First_Parent => Options.First_Parent, others => <>));
            begin
               SB.Use_Interesting := True;
               for Id of Listed loop
                  SB.Interesting.Include (Id);
               end loop;
               if Options.Reverse_Blame and then not Options.First_Parent then
                  --  Children as git's walk records them: oldest first.
                  for I in reverse Listed.First_Index .. Listed.Last_Index loop
                     declare
                        C : constant Natural := Lookup_Commit (SB, Listed (I));
                     begin
                        Parse_Commit (SB, C);
                        for P of SB.Commits (C).Parents loop
                           SB.Commits.Reference (P).Children.Append (C);
                        end loop;
                     end;
                  end loop;
               end if;
            end;
         end;
      end if;

      if Options.Reverse_Blame and then Options.First_Parent then
         declare
            C : Natural := Latest;
         begin
            Parse_Commit (SB, C);
            while not SB.Commits (C).Parents.Is_Empty and then C /= SB.Final loop
               declare
                  P : constant Natural := SB.Commits (C).Parents.First_Element;
               begin
                  SB.Commits.Reference (P).Children.Clear;
                  SB.Commits.Reference (P).Children.Append (C);
                  C := P;
                  Parse_Commit (SB, C);
               end;
            end loop;
            if C /= SB.Final then
               raise Blame_Error with
                 "--reverse --first-parent together require range along first-parent chain";
            end if;
         end;
      end if;

      --  The final image.
      if SB.Commits (SB.Final).Is_Fake then
         Final_Orig := SB.Commits (SB.Final).Origins;
         SB.Final_Text := SB.Origins (Final_Orig).File;
      else
         declare
            Found : Boolean;
            Id    : Version.Objects.Object_Id_Storage;
            Mode  : Unbounded_String;
            Kind  : Version.Objects.Tree_Entry_Kind;
         begin
            Final_Orig := Get_Origin (SB, SB.Final, Path);
            Lookup_Path (SB, SB.Final, Path, Found, Id, Mode, Kind);
            if not Found or else Kind /= Version.Objects.Tree_Blob then
               raise Blame_Error with
                 "no such path " & Path & " in " & To_String (Final_Name);
            end if;
            SB.Origins.Reference (Final_Orig).Blob := Id;
            SB.Origins.Reference (Final_Orig).Mode := Mode;
            SB.Final_Text := To_Unbounded_String (Blob_Text (SB, Path, Id));
         end;
      end if;
      SB.Num_Read_Blob := SB.Num_Read_Blob + 1;
      SB.Line_Starts := Find_Line_Starts (To_String (SB.Final_Text));
      SB.Num_Lines := Natural (SB.Line_Starts.Length) - 1;

      --  -L ranges, in order, each anchored after the previous one.
      declare
         type Line_Range is record
            Start, Stop : Natural;   --  0-based half-open
         end record;
         package Range_Vectors is new Ada.Containers.Vectors
           (Index_Type => Positive, Element_Type => Line_Range);
         Specs  : String_Vectors.Vector := Options.Ranges;
         Ranges : Range_Vectors.Vector;
         Merged : Range_Vectors.Vector;
         Anchor : Integer := 1;
         Lno    : constant Integer := SB.Num_Lines;
      begin
         if Lno > 0 and then Specs.Is_Empty then
            Specs.Append ("1");
         end if;
         for Spec of Specs loop
            declare
               Bottom, Top : Integer;
            begin
               Parse_Range_Arg (SB, Spec, Anchor, Bottom, Top);
               if (Lno = 0 and then (Top /= 0 or else Bottom /= 0))
                 or else Lno < Bottom
               then
                  raise Blame_Error with
                    "file " & Path & " has only " & Img (Lno)
                    & (if Lno = 1 then " line" else " lines");
               end if;
               if Bottom < 1 then
                  Bottom := 1;
               end if;
               if Top < 1 or else Lno < Top then
                  Top := Lno;
               end if;
               Bottom := Bottom - 1;
               Ranges.Append (Line_Range'(Start => Bottom, Stop => Top));
               Anchor := Top + 1;
            end;
         end loop;

         --  sort_and_merge_range_set
         for I in 2 .. Natural (Ranges.Length) loop
            declare
               V : constant Line_Range := Ranges (I);
               J : Natural := I;
            begin
               while J > 1 and then Ranges (J - 1).Start > V.Start loop
                  declare
                     Prev : constant Line_Range := Ranges (J - 1);
                  begin
                     Ranges.Replace_Element (J, Prev);
                  end;
                  J := J - 1;
               end loop;
               Ranges.Replace_Element (J, V);
            end;
         end loop;
         for R of Ranges loop
            if not Merged.Is_Empty and then R.Start <= Merged.Last_Element.Stop
            then
               Merged.Reference (Merged.Last_Index).Stop :=
                 Natural'Max (Merged.Last_Element.Stop, R.Stop);
            else
               Merged.Append (R);
            end if;
         end loop;

         declare
            Head : Natural := 0;
         begin
            for I in reverse 1 .. Natural (Merged.Length) loop
               Head := New_Cell
                 (SB,
                  Entry_Rec'(Next      => Head,
                             Lno       => Merged (I).Start,
                             Num_Lines => Merged (I).Stop - Merged (I).Start,
                             Suspect   => Final_Orig,
                             S_Lno     => Merged (I).Start,
                             others    => <>));
            end loop;
            Set_Next (SB, SB.Origins (Final_Orig).Suspects, Head);
         end;
      end;
      Queue_Put (SB, SB.Final);

      Assign_Blame (SB);

      --  blame_sort_final + blame_coalesce
      SB.Ent := Sort_List (SB, SB.Ent, By_Suspect => False);
      declare
         E : Natural := SB.Ent;
      begin
         while E /= 0 and then Next (SB, E) /= 0 loop
            declare
               N : constant Natural := Next (SB, E);
               A : constant Entry_Rec := SB.Cells (E);
               B : constant Entry_Rec := SB.Cells (N);
            begin
               if A.Suspect = B.Suspect
                 and then A.S_Lno + A.Num_Lines = B.S_Lno
                 and then A.Lno + A.Num_Lines = B.Lno
                 and then A.Ignored = B.Ignored
                 and then A.Unblamable = B.Unblamable
               then
                  SB.Cells.Reference (E).Num_Lines := A.Num_Lines + B.Num_Lines;
                  SB.Cells.Reference (E).Score := 0;
                  Set_Next (SB, E, Next (SB, N));
               else
                  E := N;
               end if;
            end;
         end loop;
      end;

      --  Reference counts as git would hold them at output: one per final
      --  entry, one per origin whose Previous this is.
      declare
         Refs         : Nat_Vectors.Vector;
         Guilty_Paths : Nat_Vectors.Vector;   --  per commit

         function To_Entry
           (Origin, Lno, S_Lno, Num : Natural;
            Ignored, Unblamable     : Boolean;
            Score                   : Natural) return Blame_Entry
         is
            O : Origin_Rec renames SB.Origins (Origin);
            C : Commit_Rec renames SB.Commits (O.Commit);
            R : Blame_Entry;
         begin
            R.Lno := Lno;
            R.Num_Lines := Num;
            R.S_Lno := S_Lno;
            R.Commit := C.Id;
            R.Path := O.Path;
            R.Boundary := Is_Uninteresting (SB, O.Commit);
            R.Ignored := Ignored;
            R.Unblamable := Unblamable;
            R.Score := Score;
            R.Refcnt := Refs (Origin);
            if O.Previous /= 0 then
               R.Has_Previous := True;
               R.Previous_Commit := SB.Commits (SB.Origins (O.Previous).Commit).Id;
               R.Previous_Path := SB.Origins (O.Previous).Path;
            end if;
            R.Multi_Path := Guilty_Paths (O.Commit) > 1;
            return R;
         end To_Entry;
      begin
         for I in 1 .. Natural (SB.Origins.Length) loop
            Refs.Append (0);
         end loop;
         for I in 1 .. Natural (SB.Commits.Length) loop
            Guilty_Paths.Append (0);
         end loop;
         for O of SB.Origins loop
            if O.Previous /= 0 then
               Refs.Reference (O.Previous) := Refs (O.Previous) + 1;
            end if;
            if O.Guilty then
               Guilty_Paths.Reference (O.Commit) := Guilty_Paths (O.Commit) + 1;
            end if;
         end loop;
         declare
            E : Natural := SB.Ent;
         begin
            while E /= 0 loop
               declare
                  S : constant Natural := SB.Cells (E).Suspect;
               begin
                  Refs.Reference (S) := Refs (S) + 1;
               end;
               E := Next (SB, E);
            end loop;
         end;

         declare
            E : Natural := SB.Ent;
         begin
            while E /= 0 loop
               declare
                  Score : constant Natural := Cell_Score (SB, E);
                  R     : constant Entry_Rec := SB.Cells (E);
               begin
                  Result.Entries.Append
                    (To_Entry (R.Suspect, R.Lno, R.S_Lno, R.Num_Lines,
                               R.Ignored, R.Unblamable, Score));
               end;
               E := Next (SB, E);
            end loop;
         end;
         for F of SB.Found loop
            Result.Found_Order.Append
              (To_Entry (F.Origin, F.Lno, F.S_Lno, F.Num_Lines,
                         F.Ignored, F.Unblamable, 0));
         end loop;
      end;

      Result.Final_Text := SB.Final_Text;
      Result.Line_Starts := SB.Line_Starts;
      Result.Num_Lines := SB.Num_Lines;
      Result.Has_Fake := SB.Has_Fake;
      Result.Fake_Time := SB.Fake_Time;
      if SB.Has_Fake then
         for P of SB.Commits (SB.Final).Parents loop
            Result.Fake_Parents.Append (SB.Commits (P).Id);
         end loop;
      end if;
      Result.Num_Read_Blob := SB.Num_Read_Blob;
      Result.Num_Get_Patch := SB.Num_Get_Patch;
      Result.Num_Commits := SB.Num_Commits;
      return Result;
   end Blame;

   function Nth_Line (Result : Blame_Result; Lno : Natural) return String is
   begin
      if Lno >= Result.Num_Lines then
         return "";
      end if;
      return Slice (Result.Final_Text, Result.Line_Starts (Lno) + 1,
                    Result.Line_Starts (Lno + 1));
   end Nth_Line;

end Version.Blame;
