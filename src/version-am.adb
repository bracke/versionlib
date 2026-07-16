with Ada.Containers.Vectors;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Version.Apply;
with Version.Files;
with Version.Objects;
with Version.Ref_Names;
with Version.Ref_Transaction;
with Version.Reflog;
with Version.Mailbox;
with Version.Refs;
with Version.Reset;
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

   function Is_From_Line (Line : String) return Boolean
     renames Version.Mailbox.Is_From_Line;

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
            MonS : constant String := To_String (Toks.Element (Day_Idx + 1));
            Y    : constant Long_Long_Integer :=
              Long_Long_Integer'Value (To_String (Toks.Element (Day_Idx + 2)));
            Tm   : constant String := To_String (Toks.Element (Day_Idx + 3));
            Tz   : constant String := To_String (Toks.Element (Day_Idx + 4));
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
            Version.Ref_Transaction.Add_Update (Tx, Branch_Ref, Commit, Old_Id);
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

   ----------------------------  session state  -----------------------------

   function State_Dir
     (Repo : Version.Repository.Repository_Handle) return String is
     (Version.Files.Join
        (Version.Repository.Git_Dir (Repo), "rebase-apply"));

   function In_Progress
     (Repo : Version.Repository.Repository_Handle) return Boolean is
     (Version.Files.Is_Directory (State_Dir (Repo)));

   function Pad4 (N : Natural) return String is
      S : constant String :=
        Ada.Strings.Fixed.Trim (Natural'Image (N), Ada.Strings.Left);
   begin
      return [1 .. Integer'Max (0, 4 - S'Length) => '0'] & S;
   end Pad4;

   function State_Path
     (Repo : Version.Repository.Repository_Handle; Name : String)
      return String is
     (Version.Files.Join (State_Dir (Repo), Name));

   function Read_State
     (Repo : Version.Repository.Repository_Handle; Name : String) return String
   is
   begin
      return Version.Files.Read_Binary_File (State_Path (Repo, Name));
   end Read_State;

   function Read_Int
     (Repo : Version.Repository.Repository_Handle; Name : String) return Natural
   is
   begin
      return Natural'Value
        (Ada.Strings.Fixed.Trim (Read_State (Repo, Name), Ada.Strings.Both));
   end Read_Int;

   procedure Write_State
     (Repo : Version.Repository.Repository_Handle; Name, Content : String) is
   begin
      Version.Files.Write_Binary_File (State_Path (Repo, Name), Content);
   end Write_State;

   ------------------------------  patch pieces  ----------------------------

   --  The mail parsing lives in Version.Mailbox (mailsplit/mailinfo use the
   --  same one); this adapts it to what `am` wants: a commit author line, and
   --  the diff with the "---" separator already stripped.
   procedure Parse_Patch
     (Lines       : Str_Vectors.Vector;
      Author_Line : out Unbounded_String;
      Subject     : out Unbounded_String;
      Message     : out Unbounded_String;
      Diff        : out Unbounded_String)
   is
      Text : Unbounded_String;
   begin
      for N in Lines.First_Index .. Lines.Last_Index loop
         Append (Text, Lines.Element (N));
         Append (Text, LF);
      end loop;

      declare
         Mail : constant Version.Mailbox.Message :=
           Version.Mailbox.Parse (To_String (Text));

         Patch : constant String := To_String (Mail.Patch);
         First : Natural := Patch'First;

         --  The commit message stops before the mail's trailing blank lines.
         function Trimmed_Body return String is
            B    : constant String := To_String (Mail.Body_Text);
            Last : Integer := B'Last;
         begin
            while Last >= B'First and then B (Last) = LF loop
               Last := Last - 1;
            end loop;

            return B (B'First .. Last);
         end Trimmed_Body;

         Body_Text : constant String := Trimmed_Body;
      begin
         Author_Line :=
           To_Unbounded_String
             (To_String (Mail.Author) & " "
              & Reverse_Date (To_String (Mail.Date)));
         Subject := Mail.Subject;
         Message :=
           To_Unbounded_String
             (if Body_Text'Length = 0 then To_String (Mail.Subject)
              else To_String (Mail.Subject) & LF & LF & Body_Text);

         --  Drop the "---" line itself.
         if Patch'Length >= 4
           and then Patch (Patch'First .. Patch'First + 3) = "---" & LF
         then
            First := Patch'First + 4;
         end if;

         --  A format-patch mail ends with a "-- \n<version>" signature: it is
         --  not part of the diff.
         declare
            Diff_Text : constant String :=
              (if First <= Patch'Last then Patch (First .. Patch'Last)
               else "");
            Stop : Natural := Diff_Text'Last;
            Line_Start : Natural := Diff_Text'First;
         begin
            Stop := Diff_Text'Last;

            while Line_Start <= Diff_Text'Last loop
               declare
                  Line_End : Natural := Line_Start;
               begin
                  while Line_End <= Diff_Text'Last
                    and then Diff_Text (Line_End) /= LF
                  loop
                     Line_End := Line_End + 1;
                  end loop;

                  if Diff_Text (Line_Start .. Line_End - 1) = "-- " then
                     Stop := Line_Start - 1;
                     exit;
                  end if;

                  Line_Start := Line_End + 1;
               end;
            end loop;

            Diff :=
              To_Unbounded_String
                (if Stop >= Diff_Text'First
                 then Diff_Text (Diff_Text'First .. Stop) else "");
         end;
      end;
   end Parse_Patch;

   procedure Stage_Diff
     (Repo : Version.Repository.Repository_Handle; Diff : String)
   is
      DLines     : Str_Vectors.Vector;
      Last_Minus : Unbounded_String;
   begin
      Split_Lines (Diff, DLines);
      for N in DLines.First_Index .. DLines.Last_Index loop
         declare
            DL : constant String := To_String (DLines.Element (N));
         begin
            if DL'Length >= 4 and then DL (DL'First .. DL'First + 3) = "--- " then
               Last_Minus :=
                 To_Unbounded_String (Strip_P1 (DL (DL'First + 4 .. DL'Last)));
            elsif DL'Length >= 4
              and then DL (DL'First .. DL'First + 3) = "+++ "
            then
               declare
                  New_P : constant String :=
                    Strip_P1 (DL (DL'First + 4 .. DL'Last));
               begin
                  if New_P = "" then
                     declare
                        Entries : Version.Staging.Index_Entry_Vectors.Vector :=
                          Version.Staging.Load (Repo);
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
   end Stage_Diff;

   procedure Commit_From_Index
     (Repo        : Version.Repository.Repository_Handle;
      Author_Line : String;
      Subject     : String;
      Message     : String)
   is
      Tree : constant Version.Objects.Hex_Object_Id :=
        Version.Write.Write_Tree_From_Index (Repo, Version.Staging.Load (Repo));
      Old  : constant String := Version.Refs.Current_Commit_Id (Repo);
      Parents : Version.Objects.Object_Id_Vectors.Vector;
   begin
      if Old'Length = 40 or else Old'Length = 64 then
         Parents.Append (Version.Objects.To_Object_Id (Old));
      end if;
      declare
         New_Commit : constant Version.Objects.Hex_Object_Id :=
           Version.Write.Write_Commit_With_Author
             (Repo, Tree, Parents, Author_Line, Message);
      begin
         Advance_Head (Repo, New_Commit, Old, "am: " & Subject);
      end;
   end Commit_From_Index;

   --  Apply patch N's diff and commit it; raises Data_Error if it fails.
   procedure Apply_And_Commit
     (Repo : Version.Repository.Repository_Handle; Lines : Str_Vectors.Vector)
   is
      Author_Line, Subject, Message, Diff : Unbounded_String;
   begin
      Parse_Patch (Lines, Author_Line, Subject, Message, Diff);
      Version.Apply.Apply_Patch (Repo, To_String (Diff));
      Stage_Diff (Repo, To_String (Diff));
      Commit_From_Index
        (Repo, To_String (Author_Line), To_String (Subject),
         To_String (Message));
   end Apply_And_Commit;

   --  Apply patches [next .. last]; on a failure leave the session and raise
   --  Am_Conflict, otherwise remove the session state.
   procedure Run_Queue (Repo : Version.Repository.Repository_Handle) is
   begin
      loop
         declare
            N    : constant Natural := Read_Int (Repo, "next");
            Last : constant Natural := Read_Int (Repo, "last");
         begin
            exit when N > Last;
            declare
               Patch : constant String := Read_State (Repo, Pad4 (N));
               Lines : Str_Vectors.Vector;
            begin
               Split_Lines (Patch, Lines);
               begin
                  Apply_And_Commit (Repo, Lines);
               exception
                  when Ada.IO_Exceptions.Data_Error =>
                     raise Am_Conflict
                       with "Patch failed at " & Pad4 (N);
               end;
            end;
            Write_State
              (Repo, "next",
               Ada.Strings.Fixed.Trim (Natural'Image (N + 1), Ada.Strings.Left));
         end;
      end loop;
      Version.Files.Delete_Directory_Tree_If_Exists (State_Dir (Repo));
   end Run_Queue;

   ------------------------------  public API  ------------------------------

   procedure Apply_Mailbox
     (Repo    : Version.Repository.Repository_Handle;
      Mailbox : String)
   is
      Lines   : Str_Vectors.Vector;
      Current : Unbounded_String;
      Count   : Natural := 0;

      procedure Flush is
      begin
         if Length (Current) > 0 then
            Count := Count + 1;
            Write_State (Repo, Pad4 (Count), To_String (Current));
            Current := Null_Unbounded_String;
         end if;
      end Flush;
   begin
      if In_Progress (Repo) then
         raise Ada.IO_Exceptions.Use_Error
           with "am: a session is already in progress"
                & " (--continue / --skip / --abort)";
      end if;

      Version.Files.Create_Directory_If_Missing (State_Dir (Repo));
      Split_Lines (Mailbox, Lines);
      for N in Lines.First_Index .. Lines.Last_Index loop
         if Is_From_Line (To_String (Lines.Element (N))) and then Length (Current) > 0
         then
            Flush;
         end if;
         Append (Current, Lines.Element (N));
         Append (Current, LF);
      end loop;
      Flush;

      if Count = 0 then
         Version.Files.Delete_Directory_Tree_If_Exists (State_Dir (Repo));
         return;
      end if;

      Write_State (Repo, "orig-head", Version.Refs.Current_Commit_Id (Repo));
      Write_State (Repo, "last",
                   Ada.Strings.Fixed.Trim (Natural'Image (Count),
                                           Ada.Strings.Left));
      Write_State (Repo, "next", "1");
      Run_Queue (Repo);
   end Apply_Mailbox;

   procedure Continue (Repo : Version.Repository.Repository_Handle) is
   begin
      if not In_Progress (Repo) then
         raise Ada.IO_Exceptions.Use_Error
           with "am: no session in progress";
      end if;
      declare
         N     : constant Natural := Read_Int (Repo, "next");
         Lines : Str_Vectors.Vector;
         Author_Line, Subject, Message, Diff : Unbounded_String;
      begin
         Split_Lines (Read_State (Repo, Pad4 (N)), Lines);
         Parse_Patch (Lines, Author_Line, Subject, Message, Diff);
         Commit_From_Index
           (Repo, To_String (Author_Line), To_String (Subject),
            To_String (Message));
         Write_State
           (Repo, "next",
            Ada.Strings.Fixed.Trim (Natural'Image (N + 1), Ada.Strings.Left));
      end;
      Run_Queue (Repo);
   end Continue;

   procedure Skip (Repo : Version.Repository.Repository_Handle) is
   begin
      if not In_Progress (Repo) then
         raise Ada.IO_Exceptions.Use_Error
           with "am: no session in progress";
      end if;
      Version.Reset.Reset_To_Commit (Repo, Version.Reset.Hard, "HEAD");
      declare
         N : constant Natural := Read_Int (Repo, "next");
      begin
         Write_State
           (Repo, "next",
            Ada.Strings.Fixed.Trim (Natural'Image (N + 1), Ada.Strings.Left));
      end;
      Run_Queue (Repo);
   end Skip;

   procedure Abort_Am (Repo : Version.Repository.Repository_Handle) is
   begin
      if not In_Progress (Repo) then
         raise Ada.IO_Exceptions.Use_Error
           with "am: no session in progress";
      end if;
      Version.Reset.Reset_To_Commit
        (Repo, Version.Reset.Hard,
         Ada.Strings.Fixed.Trim (Read_State (Repo, "orig-head"),
                                 Ada.Strings.Both));
      Version.Files.Delete_Directory_Tree_If_Exists (State_Dir (Repo));
   end Abort_Am;

end Version.Am;
