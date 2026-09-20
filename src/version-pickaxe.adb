with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

with Version.Merge;

package body Version.Pickaxe is

   function Occurrences (Text, Sub : String) return Natural is
      N : Natural := 0;
      I : Natural := Text'First;
   begin
      if Sub'Length = 0 then
         return 0;
      end if;
      while I + Sub'Length - 1 <= Text'Last loop
         if Text (I .. I + Sub'Length - 1) = Sub then
            N := N + 1;
            I := I + Sub'Length;
         else
            I := I + 1;
         end if;
      end loop;
      return N;
   end Occurrences;

   function Regex_Occurrences
     (Text : String; M : Version.Grep.Line_Matcher) return Natural
   is
      N     : Natural := 0;
      Start : Natural := Text'First;
   begin
      for K in Text'Range loop
         if Text (K) = ASCII.LF then
            if Version.Grep.Matches (M, Text (Start .. K - 1)) then
               N := N + 1;
            end if;
            Start := K + 1;
         end if;
      end loop;
      if Start <= Text'Last
        and then Version.Grep.Matches (M, Text (Start .. Text'Last))
      then
         N := N + 1;
      end if;
      return N;
   end Regex_Occurrences;

   function Texts_Match (Old_Text, New_Text : String; Pick : Spec) return Boolean
   is
      Pattern : constant String := To_String (Pick.Pattern);
      Opts    : constant Version.Grep.Options :=
        (Kind => Pick.Kind, Ignore_Case => Pick.Ignore_Case, others => <>);
   begin
      if not Pick.Active then
         return True;
      end if;
      if Pick.Regex then
         --  -G: a line the change added or removed matches.
         declare
            M : constant Version.Grep.Line_Matcher :=
              Version.Grep.Compile (Pattern, Opts);
            Old_Lines : constant Version.Merge.Line_Vectors.Vector :=
              Version.Merge.Split_Lines (Old_Text);
            New_Lines : constant Version.Merge.Line_Vectors.Vector :=
              Version.Merge.Split_Lines (New_Text);
            function Bare (L : String) return String is
              (if L'Length > 0 and then L (L'Last) = ASCII.LF
               then L (L'First .. L'Last - 1) else L);
         begin
            for C of Version.Merge.Text_Changes (Old_Text, New_Text) loop
               for K in C.Old_First .. C.Old_After - 1 loop
                  if Version.Grep.Matches (M, Bare (Old_Lines.Element (K))) then
                     return True;
                  end if;
               end loop;
               for K in C.New_First .. C.New_After - 1 loop
                  if Version.Grep.Matches (M, Bare (New_Lines.Element (K))) then
                     return True;
                  end if;
               end loop;
            end loop;
            return False;
         end;
      elsif Pick.Regex_String then
         declare
            M : constant Version.Grep.Line_Matcher :=
              Version.Grep.Compile (Pattern, Opts);
         begin
            return Regex_Occurrences (Old_Text, M)
              /= Regex_Occurrences (New_Text, M);
         end;
      else
         --  -S: the number of occurrences changed.
         return Occurrences (Old_Text, Pattern) /= Occurrences (New_Text, Pattern);
      end if;
   end Texts_Match;

   function Pair_Matches
     (Repo        : Version.Repository.Repository_Handle;
      Old_Present : Boolean;
      Old_Id      : Version.Objects.Hex_Object_Id;
      New_Present : Boolean;
      New_Id      : Version.Objects.Hex_Object_Id;
      Pick        : Spec) return Boolean
   is
      function Content (Present : Boolean; Id : Version.Objects.Hex_Object_Id)
        return String
      is (if Present
          then Version.Objects.Content (Version.Objects.Read_Object (Repo, Id))
          else "");
   begin
      if not Pick.Active then
         return True;
      end if;
      return Texts_Match
        (Content (Old_Present, Old_Id), Content (New_Present, New_Id), Pick);
   end Pair_Matches;

end Version.Pickaxe;
