with Ada.Characters.Handling;
with Ada.Strings.Fixed;

with Version.Files;
with Version.Staging;

package body Version.Grep is

   use Ada.Strings.Unbounded;

   LF : constant Character := Character'Val (10);

   function Search
     (Repo        : Version.Repository.Repository_Handle;
      Pattern     : String;
      Ignore_Case : Boolean := False)
      return Match_Vectors.Vector
   is
      Entries : constant Version.Staging.Index_Entry_Vectors.Vector :=
        Version.Staging.Load (Repo);
      Root    : constant String := Version.Repository.Root_Path (Repo);
      Result  : Match_Vectors.Vector;

      function Hit (Hay : String) return Boolean is
      begin
         if Pattern'Length = 0 then
            return False;
         elsif Ignore_Case then
            return Ada.Strings.Fixed.Index
                     (Ada.Characters.Handling.To_Lower (Hay),
                      Ada.Characters.Handling.To_Lower (Pattern)) /= 0;
         else
            return Ada.Strings.Fixed.Index (Hay, Pattern) /= 0;
         end if;
      end Hit;
   begin
      for E of Entries loop
         if E.Stage = 0 then
            declare
               Path : constant String := To_String (E.Path);
               Full : constant String := Version.Files.Join (Root, Path);
            begin
               if Version.Files.Is_Ordinary_File (Full) then
                  declare
                     Content : constant String :=
                       Version.Files.Read_Binary_File (Full);
                     Start   : Positive := Content'First;
                     Line_No : Positive := 1;

                     procedure Emit (Line : String) is
                     begin
                        if Hit (Line) then
                           Result.Append
                             (Match'
                                (Path    => To_Unbounded_String (Path),
                                 Line_No => Line_No,
                                 Text    => To_Unbounded_String (Line)));
                        end if;
                        Line_No := Line_No + 1;
                     end Emit;
                  begin
                     for I in Content'Range loop
                        if Content (I) = LF then
                           Emit (Content (Start .. I - 1));
                           Start := I + 1;
                        end if;
                     end loop;
                     if Start <= Content'Last then
                        Emit (Content (Start .. Content'Last));
                     end if;
                  end;
               end if;
            end;
         end if;
      end loop;
      return Result;
   end Search;

end Version.Grep;
