with Ada.Containers.Vectors;
with Ada.IO_Exceptions;
with Ada.Strings.Unbounded;

with Version.Files;
with Version.Path_Safety;

package body Version.Apply is

   use Ada.Strings.Unbounded;

   LF : constant Character := Character'Val (10);

   package Line_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Unbounded_String);

   type File_Result is record
      Path    : Unbounded_String;
      Delete  : Boolean := False;
      Content : Unbounded_String;
   end record;

   package Result_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => File_Result);

   procedure Bad_Patch (Message : String) is
   begin
      raise Ada.IO_Exceptions.Data_Error with Message;
   end Bad_Patch;

   --  Split S on LF into logical lines; Final_NL is True when S ends with LF
   --  (or is empty).
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

   --  Path token after "--- " / "+++ ", -p1 stripped; "" for /dev/null.
   function Strip_Path (Raw : String) return String is
      Stop : Natural := Raw'Last;
   begin
      --  Trim a trailing tab-delimited timestamp if present.
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
         --  Strip the first path component (-p1).
         for I in Token'Range loop
            if Token (I) = '/' then
               return Token (I + 1 .. Token'Last);
            end if;
         end loop;
         return Token;
      end;
   end Strip_Path;

   function Old_Start_Of (Header : String) return Natural is
      --  "@@ -<os>[,<oc>] +<ns>[,<nc>] @@ ..."
      I     : Natural := Header'First;
      Value : Natural := 0;
   begin
      while I <= Header'Last and then Header (I) /= '-' loop
         I := I + 1;
      end loop;
      I := I + 1;  --  past '-'
      while I <= Header'Last
        and then Header (I) in '0' .. '9'
      loop
         Value := Value * 10 + (Character'Pos (Header (I)) - Character'Pos ('0'));
         I := I + 1;
      end loop;
      return Value;
   end Old_Start_Of;

   procedure Apply_Patch
     (Repo    : Version.Repository.Repository_Handle;
      Patch   : String;
      Options : Apply_Options := (others => <>))
   is
      Root    : constant String := Version.Repository.Root_Path (Repo);
      PLines  : Line_Vectors.Vector;
      Dummy   : Boolean;
      Idx     : Positive;
      Results : Result_Vectors.Vector;

      function PLine (N : Positive) return String is
        (To_String (PLines.Element (N)));

      function Is_Body_Line (S : String) return Boolean is
        (S'Length = 0
         or else S (S'First) in ' ' | '+' | '-' | '\');
   begin
      Split_Lines (Patch, PLines, Dummy);
      if PLines.Is_Empty then
         return;
      end if;

      Idx := PLines.First_Index;
      while Idx <= PLines.Last_Index loop
         declare
            Line : constant String := PLine (Idx);
         begin
            if Line'Length >= 4 and then Line (Line'First .. Line'First + 3)
                                          = "--- "
            then
               --  Start of a file patch: "--- " then "+++ ".
               if Idx + 1 > PLines.Last_Index
                 or else PLine (Idx + 1)'Length < 4
                 or else PLine (Idx + 1) (PLine (Idx + 1)'First ..
                                          PLine (Idx + 1)'First + 3) /= "+++ "
               then
                  Bad_Patch ("malformed patch: expected +++ after ---");
               end if;

               declare
                  Old_Raw   : constant String := Line (Line'First + 4 .. Line'Last);
                  New_Raw   : constant String :=
                    PLine (Idx + 1) (PLine (Idx + 1)'First + 4 ..
                                     PLine (Idx + 1)'Last);
                  Old_Path  : constant String := Strip_Path (Old_Raw);
                  New_Path  : constant String := Strip_Path (New_Raw);
                  Is_Create : constant Boolean := Old_Path = "";
                  Is_Delete : constant Boolean := New_Path = "";
                  Target    : constant String :=
                    (if Is_Delete then Old_Path else New_Path);
                  Source    : constant String :=
                    (if Is_Create then New_Path else Old_Path);
                  Src_Full  : constant String :=
                    Version.Files.Join (Root, Source);

                  Old_Lines : Line_Vectors.Vector;
                  Old_NL    : Boolean;
                  New_Lines : Line_Vectors.Vector;
                  New_NL    : Boolean := True;
                  Old_Pos   : Positive := 1;
               begin
                  Version.Path_Safety.Require_Safe_Relative_Path
                    (Target, "apply path");

                  if not Is_Create
                    and then Version.Files.Is_Ordinary_File (Src_Full)
                  then
                     Split_Lines
                       (Version.Files.Read_Binary_File (Src_Full),
                        Old_Lines, Old_NL);
                  else
                     Old_NL := True;
                  end if;

                  Idx := Idx + 2;  --  past --- / +++

                  --  Hunks.
                  while Idx <= PLines.Last_Index
                    and then PLine (Idx)'Length >= 2
                    and then PLine (Idx) (PLine (Idx)'First .. PLine (Idx)'First + 1)
                             = "@@"
                  loop
                     declare
                        Old_Start : constant Natural := Old_Start_Of (PLine (Idx));
                     begin
                        --  Copy unchanged lines before the hunk.
                        while Old_Pos < Old_Start
                          and then Old_Pos <= Old_Lines.Last_Index
                        loop
                           New_Lines.Append (Old_Lines.Element (Old_Pos));
                           Old_Pos := Old_Pos + 1;
                        end loop;

                        Idx := Idx + 1;  --  past @@

                        while Idx <= PLines.Last_Index
                          and then Is_Body_Line (PLine (Idx))
                          and then
                            (PLine (Idx)'Length = 0
                             or else PLine (Idx) (PLine (Idx)'First) /= '@')
                        loop
                           declare
                              B    : constant String := PLine (Idx);
                              Kind : constant Character :=
                                (if B'Length = 0 then ' ' else B (B'First));
                              Text : constant String :=
                                (if B'Length <= 1 then ""
                                 else B (B'First + 1 .. B'Last));
                           begin
                              case Kind is
                                 when ' ' =>
                                    if Old_Pos > Old_Lines.Last_Index
                                      or else To_String
                                                (Old_Lines.Element (Old_Pos))
                                              /= Text
                                    then
                                       Bad_Patch
                                         ("patch does not apply (context "
                                          & "mismatch in " & Target & ")");
                                    end if;
                                    New_Lines.Append (To_Unbounded_String (Text));
                                    Old_Pos := Old_Pos + 1;

                                 when '-' =>
                                    if Old_Pos > Old_Lines.Last_Index
                                      or else To_String
                                                (Old_Lines.Element (Old_Pos))
                                              /= Text
                                    then
                                       Bad_Patch
                                         ("patch does not apply (deletion "
                                          & "mismatch in " & Target & ")");
                                    end if;
                                    Old_Pos := Old_Pos + 1;

                                 when '+' =>
                                    New_Lines.Append (To_Unbounded_String (Text));

                                 when '\' =>
                                    --  "\ No newline at end of file": the
                                    --  preceding new-side line has no newline.
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

                  --  Copy any remaining unchanged trailing lines.
                  while Old_Pos <= Old_Lines.Last_Index loop
                     New_Lines.Append (Old_Lines.Element (Old_Pos));
                     Old_Pos := Old_Pos + 1;
                  end loop;

                  Results.Append
                    (File_Result'
                       (Path    => To_Unbounded_String (Target),
                        Delete  => Is_Delete,
                        Content => To_Unbounded_String
                                     (Join_Lines (New_Lines, New_NL))));
               end;
            else
               Idx := Idx + 1;  --  skip diff/index/mode headers etc.
            end if;
         end;
      end loop;

      if Options.Check then
         return;
      end if;

      for R of Results loop
         declare
            Rel  : constant String := To_String (R.Path);
            Full : constant String := Version.Files.Join (Root, Rel);
         begin
            if R.Delete then
               Version.Files.Remove_File_If_Safe
                 (Repo_Root => Root, Relative_Path => Rel);
            else
               Version.Files.Create_Parent_Directories (Full);
               Version.Files.Write_Binary_File (Full, To_String (R.Content));
            end if;
         end;
      end loop;
   end Apply_Patch;

end Version.Apply;
