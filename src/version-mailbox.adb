with Ada.Strings.Fixed;

package body Version.Mailbox is

   LF : constant Character := Character'Val (10);

   function Is_Digit (C : Character) return Boolean is (C in '0' .. '9');

   ------------------
   -- Is_From_Line --
   ------------------

   function Is_From_Line (Line : String) return Boolean is
      Colon : Integer;
   begin
      if Line'Length < 20
        or else Line (Line'First .. Line'First + 4) /= "From "
      then
         return False;
      end if;

      --  Walk back from the end to the last ':' -- the time in the date.
      Colon := Line'Last - 1;

      while Colon >= Line'First + 5 and then Line (Colon) /= ':' loop
         Colon := Colon - 1;
      end loop;

      if Colon < Line'First + 5 then
         return False;
      end if;

      --  "hh:mm" around it, with the seconds' pair before the minute colon.
      if Colon - 4 < Line'First or else Colon + 2 > Line'Last then
         return False;
      end if;

      return Is_Digit (Line (Colon - 4))
        and then Is_Digit (Line (Colon - 2))
        and then Is_Digit (Line (Colon - 1))
        and then Is_Digit (Line (Colon + 1))
        and then Is_Digit (Line (Colon + 2));
   end Is_From_Line;

   function Lines_Of (Text : String) return Text_Vectors.Vector is
      Result : Text_Vectors.Vector;
      Start  : Natural := Text'First;
   begin
      for I in Text'Range loop
         if Text (I) = LF then
            Result.Append (Text (Start .. I - 1));
            Start := I + 1;
         end if;
      end loop;

      if Start <= Text'Last then
         Result.Append (Text (Start .. Text'Last));
      end if;

      return Result;
   end Lines_Of;

   -----------
   -- Split --
   -----------

   function Split (Mailbox : String) return Text_Vectors.Vector is
      Result  : Text_Vectors.Vector;
      Current : Unbounded_String;
   begin
      for Line of Lines_Of (Mailbox) loop
         if Is_From_Line (Line) and then Length (Current) > 0 then
            Result.Append (To_String (Current));
            Current := Null_Unbounded_String;
         end if;

         Append (Current, Line & LF);
      end loop;

      if Length (Current) > 0 then
         Result.Append (To_String (Current));
      end if;

      return Result;
   end Split;

   -----------
   -- Parse --
   -----------

   function Parse (Mail : String) return Message is
      Lines  : constant Text_Vectors.Vector := Lines_Of (Mail);
      Result : Message;

      I : Positive := Lines.First_Index;
   begin
      if not Lines.Is_Empty and then Is_From_Line (Lines.First_Element) then
         I := I + 1;
      end if;

      --  Headers, up to the blank line.
      while I <= Lines.Last_Index and then Lines.Element (I) /= "" loop
         declare
            Line : constant String := Lines.Element (I);
         begin
            if Line'Length >= 6
              and then Line (Line'First .. Line'First + 5) = "From: "
            then
               Result.Author :=
                 To_Unbounded_String (Line (Line'First + 6 .. Line'Last));
            elsif Line'Length >= 6
              and then Line (Line'First .. Line'First + 5) = "Date: "
            then
               Result.Date :=
                 To_Unbounded_String (Line (Line'First + 6 .. Line'Last));
            elsif Line'Length >= 9
              and then Line (Line'First .. Line'First + 8) = "Subject: "
            then
               Result.Subject :=
                 To_Unbounded_String (Line (Line'First + 9 .. Line'Last));
            end if;
         end;

         I := I + 1;
      end loop;

      I := I + 1;   --  past the blank line

      --  The commit message, then the patch from the "---" line on.
      declare
         Body_Text : Unbounded_String;
         Patch     : Unbounded_String;
      begin
         while I <= Lines.Last_Index and then Lines.Element (I) /= "---" loop
            Append (Body_Text, Lines.Element (I) & LF);
            I := I + 1;
         end loop;

         while I <= Lines.Last_Index loop
            Append (Patch, Lines.Element (I) & LF);
            I := I + 1;
         end loop;

         --  Verbatim: `mailinfo` writes exactly these bytes to its message
         --  file, blank lines and all.  A caller that wants a commit message
         --  (like `am`) trims them itself.
         Result.Body_Text := Body_Text;
         Result.Patch := Patch;
      end;

      --  "[PATCH v2 3/7] real subject" -> "real subject".
      declare
         Subject : constant String := To_String (Result.Subject);
      begin
         if Subject'Length > 0 and then Subject (Subject'First) = '[' then
            for K in Subject'Range loop
               if Subject (K) = ']' then
                  Result.Subject :=
                    To_Unbounded_String
                      ((if K + 2 <= Subject'Last
                        then Subject (K + 2 .. Subject'Last) else ""));
                  exit;
               end if;
            end loop;
         end if;
      end;

      --  "Name <mail>" -> the two halves.
      declare
         Author : constant String := To_String (Result.Author);
         LT     : constant Natural := Ada.Strings.Fixed.Index (Author, "<");
         GT     : constant Natural := Ada.Strings.Fixed.Index (Author, ">");
      begin
         if LT /= 0 and then GT > LT then
            Result.Author_Name :=
              To_Unbounded_String
                (Ada.Strings.Fixed.Trim
                   (Author (Author'First .. LT - 1), Ada.Strings.Both));
            Result.Author_Email :=
              To_Unbounded_String (Author (LT + 1 .. GT - 1));
         else
            Result.Author_Name := Result.Author;
         end if;
      end;

      return Result;
   end Parse;

end Version.Mailbox;
