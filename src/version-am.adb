with Ada.Containers.Vectors;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Version.Apply;
with Version.Objects;
with Version.Ref_Names;
with Version.Ref_Transaction;
with Version.Reflog;
with Version.Refs;
with Version.Staging;
with Version.Stage;
with Version.Write;

package body Version.Am is
   use Version.Objects;

   use Ada.Strings.Unbounded;

   LF : constant Character := Character'Val (10);

   package Str_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Unbounded_String);

   function Is_Hex (C : Character) return Boolean is
     (C in '0' .. '9' | 'a' .. 'f' | 'A' .. 'F');

   procedure Split_Lines (S : String; Lines : out Str_Vectors.Vector) is
      Start : Positive := S'First;
   begin
      Lines.Clear;
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
      end if;
   end Split_Lines;

   procedure Split_Spaces (S : String; Out_Tokens : out Str_Vectors.Vector) is
      Start : Natural := 0;
   begin
      Out_Tokens.Clear;
      for I in S'Range loop
         if S (I) = ' ' then
            if Start /= 0 then
               Out_Tokens.Append (To_Unbounded_String (S (Start .. I - 1)));
               Start := 0;
            end if;
         elsif Start = 0 then
            Start := I;
         end if;
      end loop;
      if Start /= 0 then
         Out_Tokens.Append (To_Unbounded_String (S (Start .. S'Last)));
      end if;
   end Split_Spaces;

   --  "From <40-hex> ..." mbox separator line.
   function Is_From_Line (Line : String) return Boolean is
   begin
      if Line'Length < 46
        or else Line (Line'First .. Line'First + 4) /= "From "
        or else Line (Line'First + 45) /= ' '
      then
         return False;
      end if;
      for K in Line'First + 5 .. Line'First + 44 loop
         if not Is_Hex (Line (K)) then
            return False;
         end if;
      end loop;
      return True;
   end Is_From_Line;

   --  -p1 path token after "--- "/"+++ "; "" for /dev/null.
   function Strip_P1 (Raw : String) return String is
      Stop : Natural := Raw'Last;
   begin
      for I in Raw'Range loop
         if Raw (I) = Character'Val (9) then
            Stop := I - 1;
            exit;
         end if;
      end loop;
      declare
         Token : constant String := Raw (Raw'First .. Stop);
      begin
         if Token = "/dev/null" then
            return "";
         end if;
         for I in Token'Range loop
            if Token (I) = '/' then
               return Token (I + 1 .. Token'Last);
            end if;
         end loop;
         return Token;
      end;
   end Strip_P1;

   --  Convert an RFC2822 date ("Wkd, D Mon YYYY HH:MM:SS +ZZZZ") to a Git
   --  author date field ("<unix-ts> <tz>").
   function Reverse_Date (S : String) return String is
      Months : constant array (1 .. 12) of String (1 .. 3) :=
        ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
         "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
      Toks : Str_Vectors.Vector;
   begin
      Split_Spaces (S, Toks);

      declare
         Day_Idx : Natural := 0;
      begin
         for I in Toks.First_Index .. Toks.Last_Index loop
            declare
               T : constant String := To_String (Toks.Element (I));
               All_Digit : Boolean := T'Length > 0;
            begin
               for C of T loop
                  if C not in '0' .. '9' then
                     All_Digit := False;
                  end if;
               end loop;
               if All_Digit then
                  Day_Idx := I;
                  exit;
               end if;
            end;
         end loop;

         if Day_Idx = 0 or else Day_Idx + 4 > Toks.Last_Index then
            return "0 +0000";
         end if;

         declare
            D    : constant Long_Long_Integer :=
              Long_Long_Integer'Value (To_String (Toks.Element (Day_Idx)));
            MonS : constant String :=
              To_String (Toks.Element (Day_Idx + 1));
            Y    : constant Long_Long_Integer :=
              Long_Long_Integer'Value (To_String (Toks.Element (Day_Idx + 2)));
            Tm   : constant String :=
              To_String (Toks.Element (Day_Idx + 3));
            Tz   : constant String :=
              To_String (Toks.Element (Day_Idx + 4));
            M    : Long_Long_Integer := 1;

            HH : constant Long_Long_Integer :=
              Long_Long_Integer'Value (Tm (Tm'First .. Tm'First + 1));
            MM : constant Long_Long_Integer :=
              Long_Long_Integer'Value (Tm (Tm'First + 3 .. Tm'First + 4));
            SS : constant Long_Long_Integer :=
              Long_Long_Integer'Value (Tm (Tm'First + 6 .. Tm'First + 7));

            Sign  : constant Long_Long_Integer :=
              (if Tz'Length >= 1 and then Tz (Tz'First) = '-' then -1 else 1);
            TZH   : constant Long_Long_Integer :=
              Long_Long_Integer'Value (Tz (Tz'First + 1 .. Tz'First + 2));
            TZM   : constant Long_Long_Integer :=
              Long_Long_Integer'Value (Tz (Tz'First + 3 .. Tz'First + 4));
         begin
            for K in Months'Range loop
               if Months (K) = MonS (MonS'First .. MonS'First + 2) then
                  M := Long_Long_Integer (K);
               end if;
            end loop;

            declare
               Yr  : constant Long_Long_Integer := Y - (if M <= 2 then 1 else 0);
               Era : constant Long_Long_Integer :=
                 (if Yr >= 0 then Yr else Yr - 399) / 400;
               Yoe : constant Long_Long_Integer := Yr - Era * 400;
               Doy : constant Long_Long_Integer :=
                 (153 * (if M > 2 then M - 3 else M + 9) + 2) / 5 + D - 1;
               Doe : constant Long_Long_Integer :=
                 Yoe * 365 + Yoe / 4 - Yoe / 100 + Doy;
               Days : constant Long_Long_Integer :=
                 Era * 146097 + Doe - 719468;
               Ts  : constant Long_Long_Integer :=
                 Days * 86400 + HH * 3600 + MM * 60 + SS
                 - Sign * (TZH * 3600 + TZM * 60);
            begin
               return Ada.Strings.Fixed.Trim
                        (Long_Long_Integer'Image (Ts), Ada.Strings.Left)
                      & " " & Tz;
            end;
         end;
      end;
   end Reverse_Date;

   procedure Advance_Head
     (Repo    : Version.Repository.Repository_Handle;
      Commit  : Version.Objects.Hex_Object_Id;
      Old_Id  : String;
      Message : String)
   is
      Head : constant Version.Refs.Head_Info := Version.Refs.Read_Head (Repo);
   begin
      if Version.Refs.Is_Attached (Head) then
         declare
            Branch_Name : constant String := Version.Refs.Branch_Name (Head);
            Branch_Ref  : constant String := "refs/heads/" & Branch_Name;
            Tx          : Version.Ref_Transaction.Transaction;
         begin
            Version.Ref_Names.Require_Branch_Name (Branch_Name);
            Version.Reflog.Preflight_Append
              (Repo, "HEAD", Version.Reflog.Data_Error_On_Lock);
            Version.Reflog.Preflight_Append
              (Repo, Branch_Ref, Version.Reflog.Data_Error_On_Lock);

            Version.Ref_Transaction.Start (Tx, Repo);
            Version.Ref_Transaction.Add_Update
              (Tx, Branch_Ref, Commit, Old_Id);
            Version.Ref_Transaction.Commit (Tx);

            Version.Reflog.Append
              (Repo, "HEAD", Old_Id, To_String (Commit), Message);
            Version.Reflog.Append
              (Repo, Branch_Ref, Old_Id, To_String (Commit), Message);
         end;
      else
         Version.Reflog.Preflight_Append
           (Repo, "HEAD", Version.Reflog.Data_Error_On_Lock);
         Version.Refs.Write_Detached_HEAD
           (Repo, Commit, Version.Objects.To_Object_Id (Old_Id));
         Version.Reflog.Append
           (Repo, "HEAD", Old_Id, To_String (Commit), Message);
      end if;
   end Advance_Head;

   procedure Apply_One
     (Repo  : Version.Repository.Repository_Handle;
      Lines : Str_Vectors.Vector)
   is
      Author_NE : Unbounded_String;
      Date_V    : Unbounded_String;
      Subject   : Unbounded_String;
      Body_Text : Unbounded_String;
      Diff      : Unbounded_String;
      I         : Positive := Lines.First_Index;

      function L (N : Positive) return String is (To_String (Lines.Element (N)));
   begin
      --  Skip the "From <sha>" separator if present.
      if I <= Lines.Last_Index and then Is_From_Line (L (I)) then
         I := I + 1;
      end if;

      --  Headers until the blank line.
      while I <= Lines.Last_Index and then L (I) /= "" loop
         declare
            Line : constant String := L (I);
         begin
            if Line'Length >= 6 and then Line (Line'First .. Line'First + 5)
                                          = "From: "
            then
               Author_NE := To_Unbounded_String (Line (Line'First + 6 .. Line'Last));
            elsif Line'Length >= 6 and then Line (Line'First .. Line'First + 5)
                                             = "Date: "
            then
               Date_V := To_Unbounded_String (Line (Line'First + 6 .. Line'Last));
            elsif Line'Length >= 9 and then Line (Line'First .. Line'First + 8)
                                             = "Subject: "
            then
               Subject := To_Unbounded_String (Line (Line'First + 9 .. Line'Last));
            end if;
         end;
         I := I + 1;
      end loop;

      I := I + 1;  --  past the blank line

      --  Body until "---".
      while I <= Lines.Last_Index and then L (I) /= "---" loop
         Append (Body_Text, L (I) & LF);
         I := I + 1;
      end loop;

      if I <= Lines.Last_Index then
         I := I + 1;  --  past "---"
      end if;

      --  Remainder is the diff, up to the mbox "-- " signature separator.
      while I <= Lines.Last_Index and then L (I) /= "-- " loop
         Append (Diff, L (I) & LF);
         I := I + 1;
      end loop;

      --  Strip a leading "[PATCH ...] " tag from the subject.
      declare
         Subj : constant String := To_String (Subject);
         Clean : Unbounded_String := Subject;
      begin
         if Subj'Length > 0 and then Subj (Subj'First) = '[' then
            for K in Subj'Range loop
               if Subj (K) = ']' then
                  Clean := To_Unbounded_String
                    ((if K + 2 <= Subj'Last then Subj (K + 2 .. Subj'Last)
                      else ""));
                  exit;
               end if;
            end loop;
         end if;
         Subject := Clean;
      end;

      --  Trim trailing newlines from the body.
      declare
         B : constant String := To_String (Body_Text);
         Last : Integer := B'Last;
      begin
         while Last >= B'First and then B (Last) = LF loop
            Last := Last - 1;
         end loop;
         Body_Text := To_Unbounded_String (B (B'First .. Last));
      end;

      --  Apply the diff to the working tree.
      Version.Apply.Apply_Patch (Repo, To_String (Diff));

      --  Stage affected paths into the index (and remove deleted ones).
      declare
         DLines : Str_Vectors.Vector;
         Last_Minus : Unbounded_String;
      begin
         Split_Lines (To_String (Diff), DLines);
         for N in DLines.First_Index .. DLines.Last_Index loop
            declare
               DL : constant String := To_String (DLines.Element (N));
            begin
               if DL'Length >= 4 and then DL (DL'First .. DL'First + 3) = "--- "
               then
                  Last_Minus := To_Unbounded_String
                    (Strip_P1 (DL (DL'First + 4 .. DL'Last)));
               elsif DL'Length >= 4
                 and then DL (DL'First .. DL'First + 3) = "+++ "
               then
                  declare
                     New_P : constant String :=
                       Strip_P1 (DL (DL'First + 4 .. DL'Last));
                  begin
                     if New_P = "" then
                        --  Deletion: drop the old path from the index.
                        declare
                           Entries : Version.Staging.Index_Entry_Vectors.Vector
                             := Version.Staging.Load (Repo);
                        begin
                           Version.Staging.Remove_Path
                             (Entries, To_String (Last_Minus));
                           Version.Staging.Write (Repo, Entries);
                        end;
                     else
                        Version.Stage.Stage_Path (New_P);
                     end if;
                  end;
               end if;
            end;
         end loop;
      end;

      --  Commit with the patch's authorship.
      declare
         Tree : constant Version.Objects.Hex_Object_Id :=
           Version.Write.Write_Tree_From_Index
             (Repo, Version.Staging.Load (Repo));
         Old  : constant String := Version.Refs.Current_Commit_Id (Repo);
         Parents : Version.Objects.Object_Id_Vectors.Vector;
         Author_Line : constant String :=
           To_String (Author_NE) & " " & Reverse_Date (To_String (Date_V));
         Message : constant String :=
           (if Length (Body_Text) = 0 then To_String (Subject)
            else To_String (Subject) & LF & LF & To_String (Body_Text));
      begin
         if Old'Length = 40 or else Old'Length = 64 then
            Parents.Append (Version.Objects.To_Object_Id (Old));
         end if;

         declare
            New_Commit : constant Version.Objects.Hex_Object_Id :=
              Version.Write.Write_Commit_With_Author
                (Repo, Tree, Parents, Author_Line, Message);
         begin
            Advance_Head (Repo, New_Commit, Old, "am: " & To_String (Subject));
         end;
      end;
   end Apply_One;

   procedure Apply_Mailbox
     (Repo    : Version.Repository.Repository_Handle;
      Mailbox : String)
   is
      Lines   : Str_Vectors.Vector;
      Current : Str_Vectors.Vector;

      procedure Flush is
      begin
         if not Current.Is_Empty then
            Apply_One (Repo, Current);
            Current.Clear;
         end if;
      end Flush;
   begin
      Split_Lines (Mailbox, Lines);
      for N in Lines.First_Index .. Lines.Last_Index loop
         if Is_From_Line (To_String (Lines.Element (N))) then
            Flush;
         end if;
         Current.Append (Lines.Element (N));
      end loop;
      Flush;
   end Apply_Mailbox;

end Version.Am;
