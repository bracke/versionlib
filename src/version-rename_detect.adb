with Ada.Containers.Ordered_Maps;
with Ada.Containers.Generic_Array_Sort;

with Interfaces; use Interfaces;

package body Version.Rename_Detect is

   LF : constant Character := Character'Val (10);

   --  diffcore-delta.c: chunks are delimited by LF or 64 bytes, whichever
   --  comes first, and hashed into this many buckets.
   Hash_Base  : constant := 107_927;
   Span_Limit : constant := 64;

   function Is_Binary (Content : String) return Boolean is
      --  xdiff-interface.c: FIRST_FEW_BYTES.
      Last : constant Natural :=
        Natural'Min (Content'Last, Content'First + 8_000 - 1);
   begin
      for I in Content'First .. Last loop
         if Content (I) = Character'Val (0) then
            return True;
         end if;
      end loop;

      return False;
   end Is_Binary;

   --  A span hash table, collapsed to "distinct hash value -> total count".
   --  git open-addresses a real table and then sorts it by hash value; since
   --  add_spanhash() accumulates into the slot already holding a given hash
   --  value, the sorted result is exactly this map walked in key order.
   package Span_Maps is new Ada.Containers.Ordered_Maps
     (Key_Type => Unsigned_32, Element_Type => Unsigned_64);

   procedure Hash_Chars (Content : String; Spans : out Span_Maps.Map) is
      Is_Text : constant Boolean := not Is_Binary (Content);
      Accum1  : Unsigned_32 := 0;
      Accum2  : Unsigned_32 := 0;
      N       : Natural := 0;
      I       : Natural := Content'First;

      procedure Emit is
         Hash_Value : constant Unsigned_32 :=
           (Accum1 + Accum2 * 16#61#) mod Hash_Base;
         Cur : constant Span_Maps.Cursor := Spans.Find (Hash_Value);
      begin
         if Span_Maps.Has_Element (Cur) then
            Spans.Replace_Element
              (Cur, Span_Maps.Element (Cur) + Unsigned_64 (N));
         else
            Spans.Insert (Hash_Value, Unsigned_64 (N));
         end if;
      end Emit;
   begin
      Spans.Clear;

      while I <= Content'Last loop
         declare
            C     : constant Unsigned_32 :=
              Unsigned_32 (Character'Pos (Content (I)));
            Old_1 : constant Unsigned_32 := Accum1;
         begin
            --  Ignore the CR of a CRLF pair in text, so that a line-ending
            --  change alone does not look like a rewrite.
            if Is_Text
              and then Content (I) = Character'Val (13)
              and then I < Content'Last
              and then Content (I + 1) = LF
            then
               I := I + 1;
            else
               Accum1 := Shift_Left (Accum1, 7) xor Shift_Right (Accum2, 25);
               Accum2 := Shift_Left (Accum2, 7) xor Shift_Right (Old_1, 25);
               Accum1 := Accum1 + C;
               N := N + 1;

               if N >= Span_Limit or else Content (I) = LF then
                  Emit;
                  N := 0;
                  Accum1 := 0;
                  Accum2 := 0;
               end if;

               I := I + 1;
            end if;
         end;
      end loop;

      if N > 0 then
         Emit;
      end if;
   end Hash_Chars;

   --  diffcore_count_changes(): walk both hash sequences in key order,
   --  attributing each span to "copied from source" or "literally added".
   procedure Count_Changes
     (Source, Dest : String;
      Src_Copied   : out Unsigned_64;
      Literal_Added : out Unsigned_64)
   is
      Src_Spans, Dst_Spans : Span_Maps.Map;
      S : Span_Maps.Cursor;
      D : Span_Maps.Cursor;
   begin
      Hash_Chars (Source, Src_Spans);
      Hash_Chars (Dest, Dst_Spans);

      Src_Copied := 0;
      Literal_Added := 0;

      S := Src_Spans.First;
      D := Dst_Spans.First;

      while Span_Maps.Has_Element (S) loop
         declare
            Src_Hash : constant Unsigned_32 := Span_Maps.Key (S);
            Src_Cnt  : constant Unsigned_64 := Span_Maps.Element (S);
            Dst_Cnt  : Unsigned_64 := 0;
         begin
            --  Destination spans the source does not have at all are added.
            while Span_Maps.Has_Element (D)
              and then Span_Maps.Key (D) < Src_Hash
            loop
               Literal_Added := Literal_Added + Span_Maps.Element (D);
               D := Span_Maps.Next (D);
            end loop;

            if Span_Maps.Has_Element (D)
              and then Span_Maps.Key (D) = Src_Hash
            then
               Dst_Cnt := Span_Maps.Element (D);
               D := Span_Maps.Next (D);
            end if;

            if Src_Cnt < Dst_Cnt then
               Literal_Added := Literal_Added + (Dst_Cnt - Src_Cnt);
               Src_Copied := Src_Copied + Src_Cnt;
            else
               Src_Copied := Src_Copied + Dst_Cnt;
            end if;
         end;

         S := Span_Maps.Next (S);
      end loop;

      while Span_Maps.Has_Element (D) loop
         Literal_Added := Literal_Added + Span_Maps.Element (D);
         D := Span_Maps.Next (D);
      end loop;
   end Count_Changes;

   function Estimate_Similarity
     (Source        : String;
      Dest          : String;
      Minimum_Score : Natural := Default_Rename_Score)
      return Natural
   is
      Src_Size  : constant Long_Long_Integer :=
        Long_Long_Integer (Source'Length);
      Dst_Size  : constant Long_Long_Integer :=
        Long_Long_Integer (Dest'Length);
      Max_Size  : constant Long_Long_Integer :=
        Long_Long_Integer'Max (Src_Size, Dst_Size);
      Base_Size : constant Long_Long_Integer :=
        Long_Long_Integer'Min (Src_Size, Dst_Size);
      Delta_Size : constant Long_Long_Integer := Max_Size - Base_Size;

      Src_Copied, Literal_Added : Unsigned_64;
   begin
      --  git refuses to consider an edit that changes the size this
      --  drastically; this also covers the Base_Size = 0 case.
      if Max_Size * Long_Long_Integer (Max_Score - Minimum_Score)
        < Delta_Size * Long_Long_Integer (Max_Score)
      then
         return 0;
      end if;

      if Dst_Size = 0 or else Max_Size = 0 then
         return 0;
      end if;

      Count_Changes (Source, Dest, Src_Copied, Literal_Added);

      return Natural
        ((Long_Long_Integer (Src_Copied) * Long_Long_Integer (Max_Score))
         / Max_Size);
   end Estimate_Similarity;

   --  Regular files only take part in inexact matching (git's S_ISREG gate).
   function Is_Regular (Mode : Unbounded_String) return Boolean is
      M : constant String := To_String (Mode);
   begin
      return M'Length >= 3 and then M (M'First .. M'First + 2) = "100";
   end Is_Regular;

   --  basename_same(): do the two paths end in the same final component?
   function Basename_Same (Left, Right : String) return Boolean is
      L : Natural := Left'Last;
      R : Natural := Right'Last;
   begin
      while L >= Left'First and then R >= Right'First loop
         if Left (L) /= Right (R) then
            return False;
         end if;
         if Left (L) = '/' then
            return True;
         end if;
         L := L - 1;
         R := R - 1;
      end loop;

      return (L < Left'First or else Left (L) = '/')
        and then (R < Right'First or else Right (R) = '/');
   end Basename_Same;

   --  The candidate matrix of diffcore-rename.c: the best few sources per
   --  destination, later sorted globally and assigned greedily.
   Candidates_Per_Dest : constant := 4;

   type Score_Entry is record
      Source     : Integer := -1;
      Dest       : Integer := -1;
      Score      : Natural := 0;
      Name_Score : Natural := 0;
   end record;

   --  score_compare(): unused entries sink, then by score descending, ties
   --  broken by name score descending.
   function Better (L, R : Score_Entry) return Boolean is
     (if L.Dest < 0 then False
      elsif R.Dest < 0 then True
      elsif L.Score /= R.Score then L.Score > R.Score
      else L.Name_Score > R.Name_Score);

   type Score_Array is array (Natural range <>) of Score_Entry;

   procedure Sort_Scores is new Ada.Containers.Generic_Array_Sort
     (Index_Type   => Natural,
      Element_Type => Score_Entry,
      Array_Type   => Score_Array,
      "<"          => Better);

   function Detect
     (Sources       : Side_Vectors.Vector;
      Dests         : Side_Vectors.Vector;
      Minimum_Score : Natural := Default_Rename_Score;
      Rename_Limit  : Natural := Default_Rename_Limit)
      return Pair_Vectors.Vector
   is
      Num_Src : constant Natural := Natural (Sources.Length);
      Num_Dst : constant Natural := Natural (Dests.Length);

      Src_Used : array (0 .. Natural'Max (Num_Src, 1) - 1) of Boolean :=
        [others => False];
      Dst_Used : array (0 .. Natural'Max (Num_Dst, 1) - 1) of Boolean :=
        [others => False];
      Dst_Score : array (0 .. Natural'Max (Num_Dst, 1) - 1) of Natural :=
        [others => 0];
      Dst_Src : array (0 .. Natural'Max (Num_Dst, 1) - 1) of Integer :=
        [others => -1];

      Result : Pair_Vectors.Vector;
   begin
      if Num_Src = 0 or else Num_Dst = 0 then
         return Result;
      end if;

      --  Pass 1, find_exact_renames(): identical blob ids. A source that has
      --  not been used yet wins over one that has, and a matching basename
      --  breaks the remaining ties -- git's score of 0, 1 or 2.
      for D in 0 .. Num_Dst - 1 loop
         declare
            Target     : constant Rename_Side := Dests.Element (D);
            Best       : Integer := -1;
            Best_Score : Integer := -1;
         begin
            for S in 0 .. Num_Src - 1 loop
               declare
                  Source : constant Rename_Side := Sources.Element (S);
                  Score  : Integer;
               begin
                  --  Non-regular files (symlinks, gitlinks) rename only when
                  --  the modes match too, since we cannot measure how similar
                  --  they are; regular files match on content alone.
                  if Source.Id = Target.Id
                    and then not Src_Used (S)
                    and then ((Is_Regular (Source.Mode)
                               and then Is_Regular (Target.Mode))
                              or else Source.Mode = Target.Mode)
                  then
                     Score :=
                       1 + (if Basename_Same
                                 (To_String (Source.Path),
                                  To_String (Target.Path))
                            then 1 else 0);
                     if Score > Best_Score then
                        Best := S;
                        Best_Score := Score;
                     end if;
                  end if;
               end;
            end loop;

            if Best >= 0 then
               Src_Used (Best) := True;
               Dst_Used (D) := True;
               Dst_Src (D) := Best;
               Dst_Score (D) := Max_Score;
            end if;
         end;
      end loop;

      --  Pass 2, the inexact matrix -- but only if git would attempt it: the
      --  cross product must fit inside the rename limit's square.
      if Minimum_Score < Max_Score
        and then (Rename_Limit = 0
                  or else Long_Long_Integer (Num_Src)
                            * Long_Long_Integer (Num_Dst)
                          <= Long_Long_Integer (Rename_Limit)
                            * Long_Long_Integer (Rename_Limit))
      then
         declare
            Matrix : Score_Array (0 .. Num_Dst * Candidates_Per_Dest - 1) :=
              [others => (others => <>)];
            Filled : Natural := 0;
         begin
            for D in 0 .. Num_Dst - 1 loop
               if not Dst_Used (D) then
                  declare
                     Target : constant Rename_Side := Dests.Element (D);
                     Best   : Score_Array (0 .. Candidates_Per_Dest - 1) :=
                       [others => (others => <>)];
                     Dst_Text : constant String :=
                       (if Is_Regular (Target.Mode)
                        then Content_Of (Target) else "");
                  begin
                     if Is_Regular (Target.Mode) then
                        for S in 0 .. Num_Src - 1 loop
                           if not Src_Used (S) then
                              declare
                                 Source : constant Rename_Side :=
                                   Sources.Element (S);
                              begin
                                 if Is_Regular (Source.Mode) then
                                    declare
                                       This : constant Score_Entry :=
                                         (Source => S,
                                          Dest   => D,
                                          Score  =>
                                            Estimate_Similarity
                                              (Content_Of (Source),
                                               Dst_Text, Minimum_Score),
                                          Name_Score =>
                                            (if Basename_Same
                                                  (To_String (Source.Path),
                                                   To_String (Target.Path))
                                             then 1 else 0));
                                       Worst : Natural := Best'First;
                                    begin
                                       --  record_if_better(): displace the
                                       --  weakest candidate held so far.
                                       for K in Best'Range loop
                                          if Better (Best (Worst), Best (K))
                                          then
                                             Worst := K;
                                          end if;
                                       end loop;

                                       if Better (This, Best (Worst)) then
                                          Best (Worst) := This;
                                       end if;
                                    end;
                                 end if;
                              end;
                           end if;
                        end loop;
                     end if;

                     for K in Best'Range loop
                        Matrix (Filled) := Best (K);
                        Filled := Filled + 1;
                     end loop;
                  end;
               end if;
            end loop;

            if Filled > 0 then
               declare
                  Live : Score_Array := Matrix (0 .. Filled - 1);
               begin
                  Sort_Scores (Live);

                  --  find_renames(): take pairs best-first, skipping any whose
                  --  source or destination has already been claimed.
                  for K in Live'Range loop
                     exit when Live (K).Dest < 0
                       or else Live (K).Score < Minimum_Score;

                     if not Dst_Used (Live (K).Dest)
                       and then not Src_Used (Live (K).Source)
                     then
                        Dst_Used (Live (K).Dest) := True;
                        Src_Used (Live (K).Source) := True;
                        Dst_Src (Live (K).Dest) := Live (K).Source;
                        Dst_Score (Live (K).Dest) := Live (K).Score;
                     end if;
                  end loop;
               end;
            end if;
         end;
      end if;

      for D in 0 .. Num_Dst - 1 loop
         if Dst_Src (D) >= 0 then
            Result.Append
              (Rename_Pair'(Source => Natural (Dst_Src (D)),
                            Dest   => D,
                            Score  => Dst_Score (D)));
         end if;
      end loop;

      return Result;
   end Detect;

end Version.Rename_Detect;
