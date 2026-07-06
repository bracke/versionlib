with Ada.IO_Exceptions;
with Ada.Strings.Unbounded;

with Version.Objects; use Version.Objects;
with Version.Object_Cache;
with Version.Shallow_Cache;
with Version.Ref_Cache;

package body Version.Log is

   use Ada.Strings.Unbounded;

   function Line_Value (Text : String; Prefix : String) return String is
      Start : Natural := Text'First;
   begin
      while Start <= Text'Last loop
         declare
            Stop : Natural := Start;
         begin
            while Stop <= Text'Last and then Text (Stop) /= Character'Val (10)
            loop
               Stop := Stop + 1;
            end loop;

            if Stop > Start then
               declare
                  Line : constant String := Text (Start .. Stop - 1);
               begin
                  if Line'Length >= Prefix'Length
                    and then
                      Line (Line'First .. Line'First + Prefix'Length - 1)
                      = Prefix
                  then
                     return Line (Line'First + Prefix'Length .. Line'Last);
                  end if;
               end;
            end if;

            Start := Stop + 1;
         end;
      end loop;

      return "";
   end Line_Value;

   function Message_Body (Text : String) return String is
      Pos : Natural := Text'First;
   begin
      while Pos <= Text'Last loop
         if Text (Pos) = Character'Val (10)
           and then Pos < Text'Last
           and then Text (Pos + 1) = Character'Val (10)
         then
            if Pos + 2 <= Text'Last then
               return Text (Pos + 2 .. Text'Last);
            else
               return "";
            end if;
         end if;

         Pos := Pos + 1;
      end loop;

      return "";
   end Message_Body;

   function Author_Name_Date (Commit_Text : String) return String is
      Author  : constant String := Line_Value (Commit_Text, "author ");
      Last_GT : Natural := 0;
   begin
      if Author'Length = 0 then
         return "";
      end if;

      for I in reverse Author'Range loop
         if Author (I) = '>' then
            Last_GT := I;
            exit;
         end if;
      end loop;

      if Last_GT = 0 or else Last_GT = Author'Last then
         return Author;
      end if;

      return Author (Author'First .. Last_GT);
   end Author_Name_Date;

   function Author_Date (Commit_Text : String) return String is
      Author  : constant String := Line_Value (Commit_Text, "author ");
      Last_GT : Natural := 0;
   begin
      if Author'Length = 0 then
         return "";
      end if;

      for I in reverse Author'Range loop
         if Author (I) = '>' then
            Last_GT := I;
            exit;
         end if;
      end loop;

      if Last_GT = 0 or else Last_GT + 2 > Author'Last then
         return "";
      end if;

      return Author (Last_GT + 2 .. Author'Last);
   end Author_Date;

   procedure Append_Line (Result : in out Unbounded_String; Text : String) is
   begin
      Append (Result, Text);
      Append (Result, Character'Val (10));
   end Append_Line;

   procedure Append_Indented_Message
     (Result : in out Unbounded_String; Message : String)
   is
      Start : Natural := Message'First;
   begin
      if Message'Length = 0 then
         return;
      end if;

      while Start <= Message'Last loop
         declare
            Stop : Natural := Start;
         begin
            while Stop <= Message'Last
              and then Message (Stop) /= Character'Val (10)
            loop
               Stop := Stop + 1;
            end loop;

            if Stop = Start then
               Append_Line (Result, "");
            else
               Append_Line (Result, "    " & Message (Start .. Stop - 1));
            end if;

            Start := Stop + 1;
         end;
      end loop;
   end Append_Indented_Message;

   function Short_Id (Id : String) return String is
   begin
      if Id'Length > 12 then
         return Id (Id'First .. Id'First + 11);
      else
         return Id;
      end if;
   end Short_Id;

   function Format_Commit_Oneline_With_Cache
     (Repo      : Version.Repository.Repository_Handle;
      Cache     : in out Version.Object_Cache.Object_Cache;
      Commit_Id : Version.Objects.Hex_Object_Id) return String
   is
      Obj : constant Version.Objects.Git_Object :=
        Version.Object_Cache.Read_Object
          (Repo => Repo, Cache => Cache, Id => Commit_Id);
   begin
      if Version.Objects.Kind (Obj) /= Version.Objects.Commit_Object then
         raise Ada.IO_Exceptions.Data_Error
           with "object is not a commit: " & To_String (Commit_Id);
      end if;

      return
        Short_Id (To_String (Commit_Id))
        & " "
        & Version.Objects.Commit_Message_First_Line (Obj);
   end Format_Commit_Oneline_With_Cache;

   function Format_Commit_With_Cache
     (Repo         : Version.Repository.Repository_Handle;
      Cache        : in out Version.Object_Cache.Object_Cache;
      Commit_Id    : Version.Objects.Hex_Object_Id;
      Full_Message : Boolean := False) return String
   is
      Obj     : constant Version.Objects.Git_Object :=
        Version.Object_Cache.Read_Object
          (Repo => Repo, Cache => Cache, Id => Commit_Id);
      Content : constant String := Version.Objects.Content (Obj);
      Result  : Unbounded_String;
      Message : constant String :=
        (if Full_Message
         then Message_Body (Content)
         else Version.Objects.Commit_Message_First_Line (Obj));
   begin
      if Version.Objects.Kind (Obj) /= Version.Objects.Commit_Object then
         raise Ada.IO_Exceptions.Data_Error
           with "object is not a commit: " & To_String (Commit_Id);
      end if;

      Append_Line (Result, "commit " & To_String (Commit_Id));
      Append_Line (Result, "Author: " & Author_Name_Date (Content));
      Append_Line (Result, "Date:   " & Author_Date (Content));
      Append_Line (Result, "");
      Append_Indented_Message (Result, Message);

      return To_String (Result);
   end Format_Commit_With_Cache;

   function Format_Commit
     (Repo         : Version.Repository.Repository_Handle;
      Commit_Id    : Version.Objects.Hex_Object_Id;
      Full_Message : Boolean := False) return String
   is
      Cache : Version.Object_Cache.Object_Cache;
   begin
      return
        Format_Commit_With_Cache
          (Repo         => Repo,
           Cache        => Cache,
           Commit_Id    => Commit_Id,
           Full_Message => Full_Message);
   end Format_Commit;

   function Log_From_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id) return String
   is
      Current : Unbounded_String := To_Unbounded_String (To_String (Commit_Id));
      Result  : Unbounded_String;
      Objects : Version.Object_Cache.Object_Cache;
      Shallow : Version.Shallow_Cache.Shallow_Cache;
   begin
      while Length (Current) > 0 loop
         declare
            Id_Text : constant String := To_String (Current);
         begin
            if not Version.Objects.Is_Valid_Hex_Object_Id (Id_Text) then
               raise Ada.IO_Exceptions.Data_Error
                 with "corrupt repository: invalid commit id";
            end if;

            declare
               Current_Id : constant Version.Objects.Hex_Object_Id :=
                 Version.Objects.To_Object_Id (Id_Text);
               Obj        : constant Version.Objects.Git_Object :=
                 Version.Object_Cache.Read_Object
                   (Repo => Repo, Cache => Objects, Id => Current_Id);
            begin
               if Version.Objects.Kind (Obj) /= Version.Objects.Commit_Object
               then
                  raise Ada.IO_Exceptions.Data_Error
                    with "object is not a commit: " & To_String (Current_Id);
               end if;

               Append
                 (Result,
                  Format_Commit_With_Cache
                    (Repo => Repo, Cache => Objects, Commit_Id => Current_Id));
               Append_Line (Result, "");
               if Version.Shallow_Cache.Is_Boundary (Repo, Shallow, Current_Id)
               then
                  Current := Null_Unbounded_String;
               else
                  Current :=
                    To_Unbounded_String
                      (Version.Objects.Commit_Parent_Id (Obj));
               end if;
            end;
         end;
      end loop;

      return To_String (Result);
   end Log_From_Commit;

   function Log_Oneline_From_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id) return String
   is
      Current : Unbounded_String := To_Unbounded_String (To_String (Commit_Id));
      Result  : Unbounded_String;
      Objects : Version.Object_Cache.Object_Cache;
      Shallow : Version.Shallow_Cache.Shallow_Cache;
   begin
      while Length (Current) > 0 loop
         declare
            Id_Text : constant String := To_String (Current);
         begin
            if not Version.Objects.Is_Valid_Hex_Object_Id (Id_Text) then
               raise Ada.IO_Exceptions.Data_Error
                 with "corrupt repository: invalid commit id";
            end if;

            declare
               Current_Id : constant Version.Objects.Hex_Object_Id :=
                 Version.Objects.To_Object_Id (Id_Text);
               Obj        : constant Version.Objects.Git_Object :=
                 Version.Object_Cache.Read_Object
                   (Repo => Repo, Cache => Objects, Id => Current_Id);
            begin
               if Version.Objects.Kind (Obj) /= Version.Objects.Commit_Object
               then
                  raise Ada.IO_Exceptions.Data_Error
                    with "object is not a commit: " & To_String (Current_Id);
               end if;

               Append_Line
                 (Result,
                  Format_Commit_Oneline_With_Cache
                    (Repo => Repo, Cache => Objects, Commit_Id => Current_Id));

               if Version.Shallow_Cache.Is_Boundary (Repo, Shallow, Current_Id)
               then
                  Current := Null_Unbounded_String;
               else
                  Current :=
                    To_Unbounded_String
                      (Version.Objects.Commit_Parent_Id (Obj));
               end if;
            end;
         end;
      end loop;

      return To_String (Result);
   end Log_Oneline_From_Commit;

   function Log_Head
     (Repo : Version.Repository.Repository_Handle) return String
   is
      Refs    : Version.Ref_Cache.Ref_Cache;
      Current : constant String :=
        Version.Ref_Cache.Current_Commit_Id (Repo => Repo, Cache => Refs);
   begin
      if Current'Length = 0 then
         return "No saved history" & Character'Val (10);
      end if;

      if not Version.Objects.Is_Valid_Hex_Object_Id (Current) then
         raise Ada.IO_Exceptions.Data_Error
           with "corrupt repository: invalid commit id";
      end if;

      return Log_From_Commit (Repo, Version.Objects.To_Object_Id (Current));
   end Log_Head;

   function Log_Oneline_Head
     (Repo : Version.Repository.Repository_Handle) return String
   is
      Refs    : Version.Ref_Cache.Ref_Cache;
      Current : constant String :=
        Version.Ref_Cache.Current_Commit_Id (Repo => Repo, Cache => Refs);
   begin
      if Current'Length = 0 then
         return "No saved history" & Character'Val (10);
      end if;

      if not Version.Objects.Is_Valid_Hex_Object_Id (Current) then
         raise Ada.IO_Exceptions.Data_Error
           with "corrupt repository: invalid commit id";
      end if;

      return
        Log_Oneline_From_Commit
          (Repo, Version.Objects.To_Object_Id (Current));
   end Log_Oneline_Head;

end Version.Log;
