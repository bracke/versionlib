with Ada.Characters.Latin_1;
with Ada.Containers.Indefinite_Vectors;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

package body Version.Stripspace is

   LF : Character renames Ada.Characters.Latin_1.LF;
   HT : Character renames Ada.Characters.Latin_1.HT;

   package Line_Vectors is new
     Ada.Containers.Indefinite_Vectors (Positive, String);

   function Split_Lines (S : String) return Line_Vectors.Vector is
      Result : Line_Vectors.Vector;
      Start  : Positive := (if S'Length > 0 then S'First else 1);
   begin
      if S'Length = 0 then
         return Result;
      end if;
      for I in S'Range loop
         if S (I) = LF then
            Result.Append (S (Start .. I - 1));
            Start := I + 1;
         end if;
      end loop;
      if Start <= S'Last then
         Result.Append (S (Start .. S'Last));
      end if;
      return Result;
   end Split_Lines;

   --  Drop trailing spaces and tabs.
   function Rstrip (Line : String) return String is
      Last : Integer := Line'Last;
   begin
      while Last >= Line'First
        and then (Line (Last) = ' ' or else Line (Last) = HT)
      loop
         Last := Last - 1;
      end loop;
      return Line (Line'First .. Last);
   end Rstrip;

   function Clean
     (Input        : String;
      Kind         : Mode      := Default;
      Comment_Char : Character := '#')
      return String
   is
      Lines : constant Line_Vectors.Vector := Split_Lines (Input);
      Out_B : Unbounded_String;
   begin
      if Kind = Comment_Lines then
         for Line of Lines loop
            if Line'Length = 0 then
               Append (Out_B, Comment_Char);
            else
               Append (Out_B, Comment_Char & " " & Line);
            end if;
            Append (Out_B, LF);
         end loop;
         return To_String (Out_B);
      end if;

      declare
         Pending_Blank : Boolean := False;
         Seen_Content  : Boolean := False;
      begin
         for Line of Lines loop
            if Kind = Strip_Comments
              and then Line'Length > 0
              and then Line (Line'First) = Comment_Char
            then
               null;  --  comment line removed entirely
            else
               declare
                  Stripped : constant String := Rstrip (Line);
               begin
                  if Stripped'Length = 0 then
                     if Seen_Content then
                        Pending_Blank := True;  --  collapse; defer emission
                     end if;
                  else
                     if Pending_Blank then
                        Append (Out_B, LF);
                        Pending_Blank := False;
                     end if;
                     Append (Out_B, Stripped);
                     Append (Out_B, LF);
                     Seen_Content := True;
                  end if;
               end;
            end if;
         end loop;
      end;

      return To_String (Out_B);
   end Clean;

end Version.Stripspace;
