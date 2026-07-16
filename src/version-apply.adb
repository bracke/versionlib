with Ada.Containers.Vectors;
with Ada.IO_Exceptions;
with Ada.Strings.Unbounded;

with Interfaces;

with Zlib;

with Version.Files;
with Version.Objects;
with Version.Path_Safety;
with Version.Staging;
with Version.Write;

package body Version.Apply is

   use Ada.Strings.Unbounded;

   LF : constant Character := Character'Val (10);
   HT : constant Character := Character'Val (9);

   package Line_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Unbounded_String);

   type File_Result is record
      Path      : Unbounded_String;   --  target path
      Old_Path  : Unbounded_String;   --  source path (rename); else = Path
      Delete    : Boolean := False;
      Is_Rename : Boolean := False;
      Has_Body  : Boolean := False;   --  content changed via hunks
      Content   : Unbounded_String;
      New_Mode  : Unbounded_String;   --  "" = unchanged, else "100755"/"100644"
   end record;

   package Result_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => File_Result);

   procedure Bad_Patch (Message : String) is
   begin
      raise Ada.IO_Exceptions.Data_Error with Message;
   end Bad_Patch;

   procedure Split_Lines
     (S        : String;
      Lines    : out Line_Vectors.Vector;
      Final_NL : out Boolean)
   is
      Start : Positive := S'First;
   begin
      Lines.Clear;
      Final_NL := True;
      if S'Length = 0 then
         return;
      end if;
      for I in S'Range loop
         if S (I) = LF then
            Lines.Append (To_Unbounded_String (S (Start .. I - 1)));
            Start := I + 1;
         end if;
      end loop;
      if Start <= S'Last then
         Lines.Append (To_Unbounded_String (S (Start .. S'Last)));
         Final_NL := False;
      end if;
   end Split_Lines;

   function Join_Lines
     (Lines : Line_Vectors.Vector; Final_NL : Boolean) return String
   is
      Result : Unbounded_String;
   begin
      for I in Lines.First_Index .. Lines.Last_Index loop
         Append (Result, Lines.Element (I));
         if I < Lines.Last_Index or else Final_NL then
            Append (Result, LF);
         end if;
      end loop;
      return To_String (Result);
   end Join_Lines;

   function Starts (S, Prefix : String) return Boolean is
     (S'Length >= Prefix'Length
      and then S (S'First .. S'First + Prefix'Length - 1) = Prefix);

   --  Strip a trailing tab-delimited timestamp and any "a/"/"b/" style leading
   --  path components per -p<Strip>.  "/dev/null" maps to "".
   function Strip_Path (Raw : String; Strip : Natural) return String is
      Stop : Natural := Raw'Last;
   begin
      for I in Raw'Range loop
         if Raw (I) = HT then
            Stop := I - 1;
            exit;
         end if;
      end loop;

      declare
         Token : constant String := Raw (Raw'First .. Stop);
         First : Natural := Token'First;
      begin
         if Token = "/dev/null" then
            return "";
         end if;
         for K in 1 .. Strip loop
            declare
               Slash : Natural := 0;
            begin
               for I in First .. Token'Last loop
                  if Token (I) = '/' then
                     Slash := I;
                     exit;
                  end if;
               end loop;
               exit when Slash = 0;
               First := Slash + 1;
            end;
         end loop;
         return Token (First .. Token'Last);
      end;
   end Strip_Path;

   function Old_Start_Of (Header : String) return Natural is
      I     : Natural := Header'First;
      Value : Natural := 0;
   begin
      while I <= Header'Last and then Header (I) /= '-' loop
         I := I + 1;
      end loop;
      I := I + 1;
      while I <= Header'Last and then Header (I) in '0' .. '9' loop
         Value := Value * 10 + (Character'Pos (Header (I)) - Character'Pos ('0'));
         I := I + 1;
      end loop;
      return Value;
   end Old_Start_Of;

   --  Reverse-transform a unified diff so the forward applier undoes it (-R):
   --  swap ---/+++ contents, hunk old/new ranges, +/- body lines, git rename
   --  and mode directions.
   function Reverse_Patch (Patch : String) return String is
      Lines    : Line_Vectors.Vector;
      NL       : Boolean;
      Out_Buf  : Unbounded_String;
      Held_Old : Unbounded_String;
      Have_Old : Boolean := False;

      function Swap_Hunk (H : String) return String is
         --  "@@ -a,b +c,d @@..." -> "@@ -c,d +d... " swap the two ranges.
         P_Minus : Natural := 0;
         P_Plus  : Natural := 0;
         P_At2   : Natural := 0;
      begin
         for I in H'First .. H'Last loop
            if H (I) = '-' and then P_Minus = 0 then
               P_Minus := I;
            elsif H (I) = '+' and then P_Minus /= 0 and then P_Plus = 0 then
               P_Plus := I;
            elsif I + 1 <= H'Last and then H (I) = '@' and then H (I + 1) = '@'
              and then P_Plus /= 0 and then P_At2 = 0 and then I > P_Plus
            then
               P_At2 := I;
            end if;
         end loop;
         if P_Minus = 0 or else P_Plus = 0 or else P_At2 = 0 then
            return H;
         end if;
         declare
            Old_Range : constant String := H (P_Minus + 1 .. P_Plus - 2);
            New_Range : constant String := H (P_Plus + 1 .. P_At2 - 2);
            Tail      : constant String := H (P_At2 .. H'Last);
         begin
            return "@@ -" & New_Range & " +" & Old_Range & " " & Tail;
         end;
      end Swap_Hunk;
   begin
      Split_Lines (Patch, Lines, NL);
      for I in Lines.First_Index .. Lines.Last_Index loop
         declare
            L : constant String := To_String (Lines.Element (I));
         begin
            if Starts (L, "--- ") then
               Held_Old := To_Unbounded_String (L (L'First + 4 .. L'Last));
               Have_Old := True;
            elsif Starts (L, "+++ ") and then Have_Old then
               Append (Out_Buf, "--- " & L (L'First + 4 .. L'Last) & LF);
               Append (Out_Buf, "+++ " & To_String (Held_Old) & LF);
               Have_Old := False;
            elsif Starts (L, "@@") then
               Append (Out_Buf, Swap_Hunk (L) & LF);
            elsif Starts (L, "diff --git ") then
               Append (Out_Buf, L & LF);   --  paths symmetric enough for apply
            elsif Starts (L, "rename from ") then
               Append (Out_Buf, "rename to " & L (L'First + 12 .. L'Last) & LF);
            elsif Starts (L, "rename to ") then
               Append (Out_Buf, "rename from " & L (L'First + 10 .. L'Last) & LF);
            elsif Starts (L, "old mode ") then
               Append (Out_Buf, "new mode " & L (L'First + 9 .. L'Last) & LF);
            elsif Starts (L, "new mode ") then
               Append (Out_Buf, "old mode " & L (L'First + 9 .. L'Last) & LF);
            elsif Starts (L, "new file mode ") then
               Append (Out_Buf,
                       "deleted file mode " & L (L'First + 14 .. L'Last) & LF);
            elsif Starts (L, "deleted file mode ") then
               Append (Out_Buf,
                       "new file mode " & L (L'First + 18 .. L'Last) & LF);
            elsif L'Length >= 1 and then L (L'First) = '+' then
               Append (Out_Buf, "-" & L (L'First + 1 .. L'Last) & LF);
            elsif L'Length >= 1 and then L (L'First) = '-' then
               Append (Out_Buf, "+" & L (L'First + 1 .. L'Last) & LF);
            else
               Append (Out_Buf, L & LF);
            end if;
         end;
      end loop;
      return To_String (Out_Buf);
   end Reverse_Patch;

   --  git's base85 alphabet (base85.c): decode one "<len><data>" line to bytes.
   Base85_Alphabet : constant String :=
     "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
     & "abcdefghijklmnopqrstuvwxyz!#$%&()*+-;<=>?@^_`{|}~";

   function Base85_Digit (C : Character) return Natural is
   begin
      for I in Base85_Alphabet'Range loop
         if Base85_Alphabet (I) = C then
            return I - Base85_Alphabet'First;
         end if;
      end loop;
      Bad_Patch ("invalid base85 character in binary patch");
      return 0;
   end Base85_Digit;

   function Decode_Base85_Line (Line : String) return String is
      use Interfaces;
      Count   : Natural;
      Out_Buf : Unbounded_String;
      K       : Natural := Line'First + 1;
   begin
      if Line'Length = 0 then
         return "";
      end if;
      declare
         LC : constant Character := Line (Line'First);
      begin
         if LC in 'A' .. 'Z' then
            Count := Character'Pos (LC) - Character'Pos ('A') + 1;
         elsif LC in 'a' .. 'z' then
            Count := Character'Pos (LC) - Character'Pos ('a') + 27;
         else
            Bad_Patch ("invalid base85 length header");
            Count := 0;
         end if;
      end;
      while K + 4 <= Line'Last loop
         declare
            Acc : Unsigned_32 := 0;
         begin
            for J in 0 .. 4 loop
               Acc := Acc * 85 + Unsigned_32 (Base85_Digit (Line (K + J)));
            end loop;
            Append
              (Out_Buf,
               Character'Val (Natural (Shift_Right (Acc, 24) and 16#FF#)));
            Append
              (Out_Buf,
               Character'Val (Natural (Shift_Right (Acc, 16) and 16#FF#)));
            Append
              (Out_Buf,
               Character'Val (Natural (Shift_Right (Acc, 8) and 16#FF#)));
            Append (Out_Buf, Character'Val (Natural (Acc and 16#FF#)));
         end;
         K := K + 5;
      end loop;
      declare
         Full : constant String := To_String (Out_Buf);
      begin
         if Count <= Full'Length then
            return Full (Full'First .. Full'First + Count - 1);
         end if;
         return Full;
      end;
   end Decode_Base85_Line;

   function Inflate_Bytes (Compressed : String) return String is
      use type Zlib.Status_Code;
      In_Buf : Zlib.Byte_Array (0 .. Compressed'Length - 1);
      Status : Zlib.Status_Code;
   begin
      for I in Compressed'Range loop
         In_Buf (I - Compressed'First) :=
           Zlib.Byte (Character'Pos (Compressed (I)));
      end loop;
      declare
         Out_Bytes : constant Zlib.Byte_Array := Zlib.Inflate (In_Buf, Status);
         R         : String (1 .. Out_Bytes'Length);
      begin
         if Status /= Zlib.Ok then
            Bad_Patch ("failed to inflate binary patch data");
         end if;
         for I in Out_Bytes'Range loop
            R (I - Out_Bytes'First + 1) := Character'Val (Natural (Out_Bytes (I)));
         end loop;
         return R;
      end;
   end Inflate_Bytes;

   --  Apply a git delta (same encoding as pack deltas) to Base.
   function Apply_Git_Delta (Base : String; D : String) return String is
      use Interfaces;
      Pos    : Natural := D'First;
      Result : Unbounded_String;

      function Read_Varint return Natural is
         Val   : Natural := 0;
         Shift : Natural := 0;
         B     : Unsigned_32;
      begin
         loop
            B := Unsigned_32 (Character'Pos (D (Pos)));
            Pos := Pos + 1;
            Val := Val + Natural (B and 16#7F#) * (2 ** Shift);
            Shift := Shift + 7;
            exit when (B and 16#80#) = 0;
         end loop;
         return Val;
      end Read_Varint;

      Base_Size   : constant Natural := Read_Varint;
      Result_Size : constant Natural := Read_Varint;
      pragma Unreferenced (Base_Size, Result_Size);
   begin
      while Pos <= D'Last loop
         declare
            Op : constant Unsigned_32 := Unsigned_32 (Character'Pos (D (Pos)));
         begin
            Pos := Pos + 1;
            if (Op and 16#80#) /= 0 then
               declare
                  Offset : Natural := 0;
                  Size   : Natural := 0;
               begin
                  if (Op and 16#01#) /= 0 then
                     Offset := Offset + Character'Pos (D (Pos)); Pos := Pos + 1;
                  end if;
                  if (Op and 16#02#) /= 0 then
                     Offset := Offset + Character'Pos (D (Pos)) * 256;
                     Pos := Pos + 1;
                  end if;
                  if (Op and 16#04#) /= 0 then
                     Offset := Offset + Character'Pos (D (Pos)) * 65_536;
                     Pos := Pos + 1;
                  end if;
                  if (Op and 16#08#) /= 0 then
                     Offset := Offset + Character'Pos (D (Pos)) * 16_777_216;
                     Pos := Pos + 1;
                  end if;
                  if (Op and 16#10#) /= 0 then
                     Size := Size + Character'Pos (D (Pos)); Pos := Pos + 1;
                  end if;
                  if (Op and 16#20#) /= 0 then
                     Size := Size + Character'Pos (D (Pos)) * 256; Pos := Pos + 1;
                  end if;
                  if (Op and 16#40#) /= 0 then
                     Size := Size + Character'Pos (D (Pos)) * 65_536;
                     Pos := Pos + 1;
                  end if;
                  if Size = 0 then
                     Size := 16#10000#;
                  end if;
                  Append
                    (Result,
                     Base (Base'First + Offset ..
                           Base'First + Offset + Size - 1));
               end;
            elsif Op /= 0 then
               Append (Result, D (Pos .. Pos + Natural (Op) - 1));
               Pos := Pos + Natural (Op);
            else
               Bad_Patch ("invalid delta opcode");
            end if;
         end;
      end loop;
      return To_String (Result);
   end Apply_Git_Delta;

   procedure Apply_Patch
     (Repo    : Version.Repository.Repository_Handle;
      Patch   : String;
      Options : Apply_Options := (others => <>))
   is
      Root    : constant String := Version.Repository.Root_Path (Repo);
      Text    : constant String :=
        (if Options.Reverse_Patch then Reverse_Patch (Patch) else Patch);
      PLines  : Line_Vectors.Vector;
      Dummy   : Boolean;
      Idx     : Positive;
      Results : Result_Vectors.Vector;

      function PLine (N : Positive) return String is
        (To_String (PLines.Element (N)));

      function Is_Body_Line (S : String) return Boolean is
        (S'Length = 0 or else S (S'First) in ' ' | '+' | '-' | '\');

      --  Parse a "--- "/"+++ " unified-diff body starting at Idx (which points
      --  at the "--- " line). Returns the computed File_Result fields.
      procedure Parse_Content_Patch
        (Result : out File_Result; Force_Path : String)
      is
         Line     : constant String := PLine (Idx);
         Old_Raw  : constant String := Line (Line'First + 4 .. Line'Last);
         Plus     : constant String := PLine (Idx + 1);
         New_Raw  : constant String := Plus (Plus'First + 4 .. Plus'Last);
         Old_Path : constant String := Strip_Path (Old_Raw, Options.Strip);
         New_Path : constant String := Strip_Path (New_Raw, Options.Strip);
         Is_Create : constant Boolean := Old_Path = "";
         Is_Delete : constant Boolean := New_Path = "";
         Target   : constant String :=
           (if Force_Path'Length > 0 then Force_Path
            elsif Is_Delete then Old_Path else New_Path);
         Source   : constant String :=
           (if Is_Create then Target else Old_Path);
         Src_Full : constant String := Version.Files.Join (Root, Source);
         Old_Lines : Line_Vectors.Vector;
         Old_NL    : Boolean := True;
         New_Lines : Line_Vectors.Vector;
         New_NL    : Boolean := True;
         Old_Pos   : Positive := 1;
      begin
         Version.Path_Safety.Require_Safe_Relative_Path (Target, "apply path");
         if not Is_Create and then Version.Files.Is_Ordinary_File (Src_Full) then
            Split_Lines
              (Version.Files.Read_Binary_File (Src_Full), Old_Lines, Old_NL);
         end if;

         Idx := Idx + 2;
         while Idx <= PLines.Last_Index and then Starts (PLine (Idx), "@@") loop
            declare
               Old_Start : Natural := Old_Start_Of (PLine (Idx));
            begin
               --  Offset tolerance: if the recorded start does not line up,
               --  fall back to sequential copy from the current position.
               if Old_Start > Old_Lines.Last_Index + 1 then
                  Old_Start := Old_Pos;
               end if;
               while Old_Pos < Old_Start
                 and then Old_Pos <= Old_Lines.Last_Index
               loop
                  New_Lines.Append (Old_Lines.Element (Old_Pos));
                  Old_Pos := Old_Pos + 1;
               end loop;
               Idx := Idx + 1;
               while Idx <= PLines.Last_Index
                 and then Is_Body_Line (PLine (Idx))
                 and then (PLine (Idx)'Length = 0
                           or else PLine (Idx) (PLine (Idx)'First) /= '@')
               loop
                  declare
                     B    : constant String := PLine (Idx);
                     Kind : constant Character :=
                       (if B'Length = 0 then ' ' else B (B'First));
                     Txt  : constant String :=
                       (if B'Length <= 1 then "" else B (B'First + 1 .. B'Last));
                  begin
                     case Kind is
                        when ' ' =>
                           if Old_Pos > Old_Lines.Last_Index
                             or else To_String (Old_Lines.Element (Old_Pos))
                                     /= Txt
                           then
                              Bad_Patch
                                ("patch does not apply (context mismatch in "
                                 & Target & ")");
                           end if;
                           New_Lines.Append (To_Unbounded_String (Txt));
                           Old_Pos := Old_Pos + 1;
                        when '-' =>
                           if Old_Pos > Old_Lines.Last_Index
                             or else To_String (Old_Lines.Element (Old_Pos))
                                     /= Txt
                           then
                              Bad_Patch
                                ("patch does not apply (deletion mismatch in "
                                 & Target & ")");
                           end if;
                           Old_Pos := Old_Pos + 1;
                        when '+' =>
                           New_Lines.Append (To_Unbounded_String (Txt));
                        when '\' =>
                           if not New_Lines.Is_Empty then
                              New_NL := False;
                           end if;
                        when others =>
                           null;
                     end case;
                  end;
                  Idx := Idx + 1;
               end loop;
            end;
         end loop;

         while Old_Pos <= Old_Lines.Last_Index loop
            New_Lines.Append (Old_Lines.Element (Old_Pos));
            Old_Pos := Old_Pos + 1;
         end loop;

         Result.Path := To_Unbounded_String (Target);
         Result.Old_Path := To_Unbounded_String (Target);
         Result.Delete := Is_Delete;
         Result.Has_Body := True;
         Result.Content := To_Unbounded_String (Join_Lines (New_Lines, New_NL));
      end Parse_Content_Patch;

      --  Parse a "diff --git a/X b/Y" block: metadata (rename/mode) then an
      --  optional "--- "/"+++ " content body.
      procedure Parse_Git_Block is
         Header    : constant String := PLine (Idx);
         Body_At   : Natural := Idx + 1;
         Rename_Fr : Unbounded_String;
         Rename_To : Unbounded_String;
         New_Mode  : Unbounded_String;
         Is_Delete : Boolean := False;
         Result    : File_Result;

         --  The two paths on the "diff --git a/X b/Y" line (strip-adjusted).
         function Second_Path return String is
            Sp1 : Natural := 0;
            HG  : constant String := "diff --git ";
         begin
            for I in Header'First + HG'Length .. Header'Last loop
               if Header (I) = ' ' then
                  Sp1 := I;
                  exit;
               end if;
            end loop;
            if Sp1 = 0 then
               return "";
            end if;
            return Strip_Path (Header (Sp1 + 1 .. Header'Last), Options.Strip);
         end Second_Path;

         function First_Path return String is
            Sp1 : Natural := 0;
            HG  : constant String := "diff --git ";
         begin
            for I in Header'First + HG'Length .. Header'Last loop
               if Header (I) = ' ' then
                  Sp1 := I;
                  exit;
               end if;
            end loop;
            if Sp1 = 0 then
               return "";
            end if;
            return Strip_Path
              (Header (Header'First + HG'Length .. Sp1 - 1), Options.Strip);
         end First_Path;

         --  Parse a "GIT binary patch" (Idx points at it): decode the forward
         --  block (literal or delta, base85 + zlib) and skip the reverse block.
         procedure Parse_Binary is
            Target     : constant String := Second_Path;
            Source     : constant String := First_Path;
            Compressed : Unbounded_String;
            Is_Delta   : Boolean;
         begin
            Idx := Idx + 1;                        --  past "GIT binary patch"
            Is_Delta := Idx <= PLines.Last_Index
                        and then Starts (PLine (Idx), "delta ");
            Idx := Idx + 1;                        --  past "literal N"/"delta N"
            while Idx <= PLines.Last_Index and then PLine (Idx)'Length > 0 loop
               Append (Compressed, Decode_Base85_Line (PLine (Idx)));
               Idx := Idx + 1;
            end loop;
            declare
               Src_Full : constant String := Version.Files.Join (Root, Source);
               Inflated : constant String :=
                 Inflate_Bytes (To_String (Compressed));
               Old      : constant String :=
                 (if Version.Files.Is_Ordinary_File (Src_Full)
                  then Version.Files.Read_Binary_File (Src_Full) else "");
            begin
               Result.Path := To_Unbounded_String (Target);
               Result.Old_Path := To_Unbounded_String (Target);
               Result.Has_Body := True;
               Result.Content := To_Unbounded_String
                 (if Is_Delta then Apply_Git_Delta (Old, Inflated) else Inflated);
               if Length (Rename_To) > 0 then
                  Result.Is_Rename := True;
                  Result.Old_Path := Rename_Fr;
                  Result.Path := Rename_To;
               end if;
               Result.New_Mode := New_Mode;
               Results.Append (Result);
            end;
            --  Skip the reverse block up to the next file.
            while Idx <= PLines.Last_Index
              and then not Starts (PLine (Idx), "diff --git ")
            loop
               Idx := Idx + 1;
            end loop;
         end Parse_Binary;
      begin
         Idx := Idx + 1;
         while Idx <= PLines.Last_Index loop
            declare
               L : constant String := PLine (Idx);
            begin
               exit when Starts (L, "--- ") or else Starts (L, "diff --git ")
                 or else Starts (L, "GIT binary patch");
               if Starts (L, "rename from ") then
                  Rename_Fr := To_Unbounded_String (L (L'First + 12 .. L'Last));
               elsif Starts (L, "rename to ") then
                  Rename_To := To_Unbounded_String (L (L'First + 10 .. L'Last));
               elsif Starts (L, "new mode ") then
                  New_Mode := To_Unbounded_String (L (L'First + 9 .. L'Last));
               elsif Starts (L, "deleted file mode ") then
                  Is_Delete := True;
               end if;
               Idx := Idx + 1;
               Body_At := Idx;
            end;
         end loop;

         if Idx <= PLines.Last_Index
           and then Starts (PLine (Idx), "GIT binary patch")
         then
            Parse_Binary;
         elsif Idx <= PLines.Last_Index
           and then Starts (PLine (Idx), "--- ")
         then
            Parse_Content_Patch (Result, Force_Path => Second_Path);
            if Length (Rename_To) > 0 then
               Result.Is_Rename := True;
               Result.Old_Path := Rename_Fr;
               Result.Path := Rename_To;
            end if;
            Result.New_Mode := New_Mode;
            Results.Append (Result);
         else
            --  No content body: a pure rename and/or mode change.
            Idx := Body_At;
            if Length (Rename_To) > 0 then
               Result.Is_Rename := True;
               Result.Old_Path := Rename_Fr;
               Result.Path := Rename_To;
               Result.Has_Body := False;
               Result.New_Mode := New_Mode;
               Results.Append (Result);
            elsif Length (New_Mode) > 0 or else Is_Delete then
               Result.Path := To_Unbounded_String (Second_Path);
               Result.Old_Path := Result.Path;
               Result.Delete := Is_Delete;
               Result.New_Mode := New_Mode;
               Results.Append (Result);
            end if;
         end if;
      end Parse_Git_Block;
   begin
      Split_Lines (Text, PLines, Dummy);
      if PLines.Is_Empty then
         return;
      end if;

      Idx := PLines.First_Index;
      while Idx <= PLines.Last_Index loop
         declare
            Line : constant String := PLine (Idx);
         begin
            if Starts (Line, "diff --git ") then
               Parse_Git_Block;
            elsif Starts (Line, "--- ") then
               if Idx + 1 > PLines.Last_Index
                 or else not Starts (PLine (Idx + 1), "+++ ")
               then
                  Bad_Patch ("malformed patch: expected +++ after ---");
               end if;
               declare
                  Result : File_Result;
               begin
                  Parse_Content_Patch (Result, Force_Path => "");
                  Results.Append (Result);
               end;
            else
               Idx := Idx + 1;
            end if;
         end;
      end loop;

      if Options.Check then
         return;
      end if;

      --  Apply to the working tree (unless --cached).
      if not Options.Cached then
         for R of Results loop
            declare
               Rel  : constant String := To_String (R.Path);
               Full : constant String := Version.Files.Join (Root, Rel);
            begin
               if R.Delete then
                  Version.Files.Remove_File_If_Safe
                    (Repo_Root => Root, Relative_Path => Rel);
               else
                  declare
                     --  Compute the new content before removing the rename
                     --  source.
                     New_Content : constant String :=
                       (if R.Has_Body then To_String (R.Content)
                        elsif R.Is_Rename then
                          Version.Files.Read_Binary_File
                            (Version.Files.Join (Root, To_String (R.Old_Path)))
                        else "");
                  begin
                     if R.Is_Rename then
                        Version.Files.Remove_File_If_Safe
                          (Repo_Root => Root,
                           Relative_Path => To_String (R.Old_Path));
                     end if;
                     if R.Has_Body or else R.Is_Rename then
                        Version.Files.Create_Parent_Directories (Full);
                        Version.Files.Write_Binary_File (Full, New_Content);
                     end if;
                     if Length (R.New_Mode) > 0 then
                        Version.Files.Set_Executable
                          (Full, To_String (R.New_Mode) = "100755");
                     end if;
                  end;
               end if;
            end;
         end loop;
      end if;

      --  Apply to the index (--index or --cached).
      if Options.Update_Index or else Options.Cached then
         declare
            Entries : Version.Staging.Index_Entry_Vectors.Vector :=
              Version.Staging.Load (Repo);
         begin
            for R of Results loop
               declare
                  Rel  : constant String := To_String (R.Path);
                  Mode : constant String :=
                    (if Length (R.New_Mode) > 0 then To_String (R.New_Mode)
                     else "100644");
               begin
                  if R.Delete then
                     Version.Staging.Remove_Path (Entries, Rel);
                  else
                     if R.Is_Rename then
                        Version.Staging.Remove_Path
                          (Entries, To_String (R.Old_Path));
                     end if;
                     declare
                        Content : constant String :=
                          (if R.Has_Body then To_String (R.Content)
                           elsif R.Is_Rename then
                             Version.Files.Read_Binary_File
                               (Version.Files.Join (Root, To_String (R.Old_Path)))
                           else
                             Version.Files.Read_Binary_File
                               (Version.Files.Join (Root, Rel)));
                        Blob : constant Version.Objects.Hex_Object_Id :=
                          Version.Write.Write_Blob (Repo, Content);
                     begin
                        Version.Staging.Replace_Entry
                          (Entries,
                           (Path  => To_Unbounded_String (Rel),
                            Id    => Blob,
                            Mode  => To_Unbounded_String (Mode),
                            Stage => 0, Skip_Worktree => False));
                     end;
                  end if;
               end;
            end loop;
            Version.Staging.Sort_By_Path (Entries);
            Version.Staging.Write (Repo, Entries);
         end;
      end if;
   end Apply_Patch;

end Version.Apply;
