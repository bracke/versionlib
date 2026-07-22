with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Containers.Ordered_Sets;

with Version.History;

package body Version.Shortlog is
   use type Version.Objects.Object_Id_Storage;

   use Ada.Strings.Unbounded;

   LF : constant Character := Character'Val (10);

   package Id_Sets is new Ada.Containers.Ordered_Sets
     (Element_Type => Version.Objects.Object_Id_Storage);

   package Group_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (Key_Type     => String,
      Element_Type => Subject_Vectors.Vector,
      "="          => Subject_Vectors."=");

   function Author_Name (Content : String) return String is
      Pos : Natural := Content'First;
   begin
      while Pos <= Content'Last loop
         declare
            EOL : Natural := Content'Last + 1;
         begin
            for K in Pos .. Content'Last loop
               if Content (K) = LF then
                  EOL := K;
                  exit;
               end if;
            end loop;
            exit when Pos = EOL;  --  blank line ends headers

            declare
               Line : constant String := Content (Pos .. EOL - 1);
            begin
               if Line'Length >= 7
                 and then Line (Line'First .. Line'First + 6) = "author "
               then
                  declare
                     A : constant String := Line (Line'First + 7 .. Line'Last);
                  begin
                     for I in A'First .. A'Last - 1 loop
                        if A (I) = ' ' and then A (I + 1) = '<' then
                           return A (A'First .. I - 1);
                        end if;
                     end loop;
                     return A;
                  end;
               end if;
            end;
            Pos := EOL + 1;
         end;
      end loop;
      return "";
   end Author_Name;

   --  The author identity with its email ("Name <email>"), for shortlog -e.
   function Author_Ident (Content : String) return String is
      Pos : Natural := Content'First;
   begin
      while Pos <= Content'Last loop
         declare
            EOL : Natural := Content'Last + 1;
         begin
            for K in Pos .. Content'Last loop
               if Content (K) = LF then
                  EOL := K;
                  exit;
               end if;
            end loop;
            exit when Pos = EOL;

            declare
               Line : constant String := Content (Pos .. EOL - 1);
            begin
               if Line'Length >= 7
                 and then Line (Line'First .. Line'First + 6) = "author "
               then
                  declare
                     A : constant String :=
                       Line (Line'First + 7 .. Line'Last);
                  begin
                     for I in reverse A'Range loop
                        if A (I) = '>' then
                           return A (A'First .. I);
                        end if;
                     end loop;
                     return A;
                  end;
               end if;
            end;
            Pos := EOL + 1;
         end;
      end loop;
      return "";
   end Author_Ident;

   function Summarize
     (Repo       : Version.Repository.Repository_Handle;
      Commits    : Version.History.Commit_Id_Vectors.Vector;
      With_Email : Boolean := False)
      return Group_Vectors.Vector
   is
      Groups : Group_Maps.Map;
      Result : Group_Vectors.Vector;
   begin
      for C of Commits loop
         declare
            Obj  : constant Version.Objects.Git_Object :=
              Version.Objects.Read_Object (Repo, C);
            Name : constant String :=
              (if With_Email
               then Author_Ident (Version.Objects.Content (Obj))
               else Author_Name (Version.Objects.Content (Obj)));
            Subj : constant String :=
              Version.Objects.Commit_Message_First_Line (Obj);
         begin
            if not Groups.Contains (Name) then
               Groups.Insert (Name, Subject_Vectors.Empty_Vector);
            end if;
            declare
               V : Subject_Vectors.Vector := Groups.Element (Name);
            begin
               V.Append (To_Unbounded_String (Subj));
               Groups.Replace (Name, V);
            end;
         end;
      end loop;

      for Cur in Groups.Iterate loop
         --  git lists a group's subjects oldest-first (chronological); the
         --  traversal above accumulates them newest-first, so reverse.
         declare
            Src : constant Subject_Vectors.Vector := Group_Maps.Element (Cur);
            Rev : Subject_Vectors.Vector;
         begin
            for I in reverse Src.First_Index .. Src.Last_Index loop
               Rev.Append (Src.Element (I));
            end loop;
            Result.Append
              (Author_Group'
                 (Name     => To_Unbounded_String (Group_Maps.Key (Cur)),
                  Subjects => Rev));
         end;
      end loop;
      return Result;
   end Summarize;

   function Summarize
     (Repo : Version.Repository.Repository_Handle;
      Tip  : Version.Objects.Hex_Object_Id)
      return Group_Vectors.Vector
   is
      --  git's default walk: newest first in committer-date order, which the
      --  per-group reversal above turns into chronological order.
      Include : Version.History.Commit_Id_Vectors.Vector;
   begin
      Include.Append (Tip);
      return Summarize
        (Repo, Version.History.Rev_List (Repo => Repo, Include => Include));
   end Summarize;

end Version.Shortlog;
