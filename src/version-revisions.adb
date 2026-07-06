with Ada.Characters.Handling;
with Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;

with Version.Objects; use Version.Objects;
with Version.Object_Cache;
with Version.Pack_Index_Cache;
with Version.Ref_Cache;
with Version.Files;

package body Version.Revisions is

   function Join (Left, Right : String) return String renames Version.Files.Join;

   function Is_Hex_Digit (C : Character) return Boolean is
   begin
      return
        (C >= '0' and then C <= '9')
        or else (C >= 'a' and then C <= 'f')
        or else (C >= 'A' and then C <= 'F');
   end Is_Hex_Digit;

   function Is_Hex_Text (Text : String) return Boolean is
   begin
      if Text'Length = 0 then
         return False;
      end if;

      for C of Text loop
         if not Is_Hex_Digit (C) then
            return False;
         end if;
      end loop;

      return True;
   end Is_Hex_Text;

   function Lower (Text : String) return String is
      Result : String (Text'Range);
   begin
      for I in Text'Range loop
         Result (I) := Ada.Characters.Handling.To_Lower (Text (I));
      end loop;

      return Result;
   end Lower;

   function Has_Prefix (Text, Prefix : String) return Boolean is
   begin
      return Text'Length >= Prefix'Length
        and then Text (Text'First .. Text'First + Prefix'Length - 1) = Prefix;
   end Has_Prefix;

   function Resolve_Ref_Name
     (Repo  : Version.Repository.Repository_Handle;
      Refs  : in out Version.Ref_Cache.Ref_Cache;
      Name  : String;
      Id    : out Version.Objects.Hex_Object_Id)
      return Boolean
   is
   begin
      return Version.Ref_Cache.Try_Resolve_Ref
        (Repo  => Repo,
         Cache => Refs,
         Name  => Name,
         Id    => Id);
   end Resolve_Ref_Name;

   procedure Consider_Loose_Object
     (Candidate : Version.Objects.Hex_Object_Id;
      Prefix    : String;
      Count     : in out Natural;
      Match     : in out Version.Objects.Hex_Object_Id)
   is
      Candidate_Text : constant String := Lower (To_String (Candidate));
      Prefix_Text    : constant String := Lower (Prefix);
   begin
      if Candidate_Text'Length >= Prefix_Text'Length
        and then Candidate_Text
          (Candidate_Text'First .. Candidate_Text'First + Prefix_Text'Length - 1)
          = Prefix_Text
      then
         Count := Count + 1;
         Match := Candidate;
      end if;
   end Consider_Loose_Object;

   function Resolve_Abbreviation
     (Repo   : Version.Repository.Repository_Handle;
      Packs  : in out Version.Pack_Index_Cache.Cache;
      Prefix : String)
      return Version.Objects.Hex_Object_Id
   is
      Objects_Dir : constant String :=
        Join (Version.Repository.Common_Git_Dir (Repo), "objects");
      Search      : Ada.Directories.Search_Type;
      Dir_Entry   : Ada.Directories.Directory_Entry_Type;
      File_Search : Ada.Directories.Search_Type;
      File_Entry  : Ada.Directories.Directory_Entry_Type;
      Count       : Natural := 0;
      Match       : Version.Objects.Object_Id_Storage := Version.Objects.Zero_Object_Id;
      Search_Open : Boolean := False;
      Files_Open  : Boolean := False;
   begin
      if Prefix'Length < 4 or else not Is_Hex_Text (Prefix) then
         raise Ada.IO_Exceptions.Data_Error with "unknown revision: " & Prefix;
      end if;

      if not Ada.Directories.Exists (Objects_Dir) then
         raise Ada.IO_Exceptions.Data_Error with "unknown revision: " & Prefix;
      end if;

      Ada.Directories.Start_Search
        (Search    => Search,
         Directory => Objects_Dir,
         Pattern   => "*",
         Filter    => [Ada.Directories.Directory => True,
                       others => False]);
      Search_Open := True;

      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Dir_Entry);

         declare
            Dir_Name : constant String :=
              Ada.Directories.Simple_Name (Dir_Entry);
            Dir_Path : constant String :=
              Ada.Directories.Full_Name (Dir_Entry);
         begin
            if Dir_Name'Length = 2 and then Is_Hex_Text (Dir_Name) then
               Ada.Directories.Start_Search
                 (Search    => File_Search,
                  Directory => Dir_Path,
                  Pattern   => "*",
                  Filter    => [Ada.Directories.Ordinary_File => True,
                                others => False]);
               Files_Open := True;

               while Ada.Directories.More_Entries (File_Search) loop
                  Ada.Directories.Get_Next_Entry (File_Search, File_Entry);

                  declare
                     File_Name : constant String :=
                       Ada.Directories.Simple_Name (File_Entry);
                  begin
                     if File_Name'Length = 38 and then Is_Hex_Text (File_Name) then
                        declare
                           Candidate : constant Version.Objects.Hex_Object_Id :=
                             Version.Objects.To_Object_Id (Lower (Dir_Name & File_Name));
                        begin
                           Consider_Loose_Object
                             (Candidate => Candidate,
                              Prefix    => Prefix,
                              Count     => Count,
                              Match     => Match);
                        end;
                     end if;
                  end;
               end loop;

               Ada.Directories.End_Search (File_Search);
               Files_Open := False;
            end if;
         end;
      end loop;

      Ada.Directories.End_Search (Search);
      Search_Open := False;

      Version.Pack_Index_Cache.Load (Repo => Repo, Item => Packs);
      Version.Pack_Index_Cache.Match_Prefix
        (Item   => Packs,
         Prefix => Prefix,
         Count  => Count,
         Match  => Match);

      if Count = 0 then
         raise Ada.IO_Exceptions.Data_Error with "unknown revision: " & Prefix;
      elsif Count > 1 then
         raise Ada.IO_Exceptions.Data_Error with "ambiguous revision: " & Prefix;
      else
         return Match;
      end if;

   exception
      when others =>
         if Files_Open then
            Ada.Directories.End_Search (File_Search);
            Files_Open := False;
         end if;

         if Search_Open then
            Ada.Directories.End_Search (Search);
            Search_Open := False;
         end if;

         raise;
   end Resolve_Abbreviation;

   function Resolve_Base
     (Repo  : Version.Repository.Repository_Handle;
      Refs  : in out Version.Ref_Cache.Ref_Cache;
      Packs : in out Version.Pack_Index_Cache.Cache;
      Name  : String)
      return Version.Objects.Hex_Object_Id
   is
      Id : Version.Objects.Object_Id_Storage := Version.Objects.Zero_Object_Id;
   begin
      if Name'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with "empty revision";
      end if;

      if Name = "HEAD" then
         declare
            Head_Id : constant String := Version.Ref_Cache.Current_Commit_Id (Repo => Repo, Cache => Refs);
         begin
            if not Version.Objects.Is_Valid_Hex_Object_Id (Head_Id) then
               raise Ada.IO_Exceptions.Data_Error with
                 "HEAD does not point to a commit";
            end if;

            return Version.Objects.To_Object_Id (Head_Id);
         end;
      end if;

      if (Name'Length = 40 or else Name'Length = 64) and then Is_Hex_Text (Name) then
         return Version.Objects.To_Object_Id (Lower (Name));
      end if;

      if not Has_Prefix (Name, "refs/") then
         if Resolve_Ref_Name (Repo, Refs, "refs/heads/" & Name, Id) then
            return Id;
         end if;

         if Resolve_Ref_Name (Repo, Refs, "refs/tags/" & Name, Id) then
            return Id;
         end if;

         if Resolve_Ref_Name (Repo, Refs, "refs/remotes/" & Name, Id) then
            return Id;
         end if;
      end if;

      if Has_Prefix (Name, "refs/") then
         if Resolve_Ref_Name (Repo, Refs, Name, Id) then
            return Id;
         end if;
      end if;

      if Name'Length >= 4 and then Is_Hex_Text (Name) then
         return Resolve_Abbreviation (Repo, Packs, Name);
      end if;

      raise Ada.IO_Exceptions.Data_Error with "unknown revision: " & Name;
   end Resolve_Base;

   function Parent_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Objects   : in out Version.Object_Cache.Object_Cache;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Index     : Positive)
      return Version.Objects.Hex_Object_Id
   is
      Obj     : constant Version.Objects.Git_Object :=
        Version.Object_Cache.Read_Object (Repo, Objects, Commit_Id);
      Parents : constant Version.Objects.Object_Id_Vectors.Vector :=
        Version.Objects.Commit_Parent_Ids (Obj);
   begin
      if Version.Objects.Kind (Obj) /= Version.Objects.Commit_Object then
         raise Ada.IO_Exceptions.Data_Error with "object is not a commit: " & To_String (Commit_Id);
      end if;

      if Natural (Parents.Length) < Index then
         raise Ada.IO_Exceptions.Data_Error with "parent does not exist";
      end if;

      return Parents.Element (Parents.First_Index + Index - 1);
   end Parent_Commit;

   function Peel_Tag_Object_Id
     (Repo    : Version.Repository.Repository_Handle;
      Objects : in out Version.Object_Cache.Object_Cache;
      Id      : Version.Objects.Hex_Object_Id)
      return Version.Objects.Hex_Object_Id
   is
      Current : Version.Objects.Hex_Object_Id := Id;
   begin
      for Depth in 1 .. 100 loop
         declare
            Obj : constant Version.Objects.Git_Object :=
              Version.Object_Cache.Read_Object (Repo, Objects, Current);
         begin
            if Version.Objects.Kind (Obj) /= Version.Objects.Tag_Object then
               return Current;
            end if;

            Current := Version.Objects.Tag_Target_Id (Obj);
         end;
      end loop;

      raise Ada.IO_Exceptions.Data_Error with "tag reference chain too deep";
   end Peel_Tag_Object_Id;

   function Require_Commit
     (Repo    : Version.Repository.Repository_Handle;
      Objects : in out Version.Object_Cache.Object_Cache;
      Id      : Version.Objects.Hex_Object_Id)
      return Version.Objects.Hex_Object_Id
   is
      Peeled : constant Version.Objects.Hex_Object_Id :=
        Peel_Tag_Object_Id (Repo, Objects, Id);
      Obj : constant Version.Objects.Git_Object :=
        Version.Object_Cache.Read_Object (Repo, Objects, Peeled);
   begin
      if Version.Objects.Kind (Obj) /= Version.Objects.Commit_Object then
         raise Ada.IO_Exceptions.Data_Error with "object is not a commit: " & To_String (Id);
      end if;

      return Peeled;
   end Require_Commit;

   function To_Tree
     (Repo    : Version.Repository.Repository_Handle;
      Objects : in out Version.Object_Cache.Object_Cache;
      Id      : Version.Objects.Hex_Object_Id)
      return Version.Objects.Hex_Object_Id
   is
      Peeled : constant Version.Objects.Hex_Object_Id :=
        Peel_Tag_Object_Id (Repo, Objects, Id);
      Obj : constant Version.Objects.Git_Object :=
        Version.Object_Cache.Read_Object (Repo, Objects, Peeled);
   begin
      case Version.Objects.Kind (Obj) is
         when Version.Objects.Tree_Object =>
            return Peeled;

         when Version.Objects.Commit_Object =>
            return Version.Objects.Commit_Tree_Id (Obj);

         when others =>
            raise Ada.IO_Exceptions.Data_Error with "object is not treeish: " & To_String (Id);
      end case;
   end To_Tree;

   function Apply_Brace_Suffix
     (Repo    : Version.Repository.Repository_Handle;
      Objects : in out Version.Object_Cache.Object_Cache;
      Id      : Version.Objects.Hex_Object_Id;
      Suffix  : String)
      return Version.Objects.Hex_Object_Id
   is
   begin
      if Suffix = "commit" then
         return Require_Commit (Repo, Objects, Id);
      elsif Suffix = "tree" then
         return To_Tree (Repo, Objects, Id);
      elsif Suffix = "" then
         return Peel_Tag_Object_Id (Repo, Objects, Id);
      else
         raise Ada.IO_Exceptions.Data_Error with "invalid revision suffix: ^{" & Suffix & "}";
      end if;
   end Apply_Brace_Suffix;

   function Decimal_Value (Text : String) return Natural is
      Value : Natural := 0;
   begin
      if Text'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with "invalid revision suffix";
      end if;

      for C of Text loop
         if C < '0' or else C > '9' then
            raise Ada.IO_Exceptions.Data_Error with "invalid revision suffix";
         end if;

         Value := Value * 10 + (Character'Pos (C) - Character'Pos ('0'));
      end loop;

      return Value;
   end Decimal_Value;

   function Resolve
     (Repo : Version.Repository.Repository_Handle;
      Text : String;
      Kind : Revision_Kind := Any_Object)
      return Version.Objects.Hex_Object_Id
   is
      Rev        : constant String := Ada.Strings.Fixed.Trim (Text, Ada.Strings.Both);
      Base_Last  : Natural := Rev'First - 1;
      Pos        : Natural;
      Current    : Version.Objects.Object_Id_Storage := Version.Objects.Zero_Object_Id;
      Objects    : Version.Object_Cache.Object_Cache;
      Refs       : Version.Ref_Cache.Ref_Cache;
      Packs      : Version.Pack_Index_Cache.Cache;
   begin
      if Rev'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with "empty revision";
      end if;

      Pos := Rev'First;
      while Pos <= Rev'Last loop
         exit when Rev (Pos) = '^' or else Rev (Pos) = '~';
         Base_Last := Pos;
         Pos := Pos + 1;
      end loop;

      if Base_Last < Rev'First then
         raise Ada.IO_Exceptions.Data_Error with "empty revision";
      end if;

      Current := Resolve_Base (Repo, Refs, Packs, Rev (Rev'First .. Base_Last));

      while Pos <= Rev'Last loop
         if Rev (Pos) = '^' then
            if Pos < Rev'Last and then Rev (Pos + 1) = '{' then
               declare
                  Close : Natural := 0;
               begin
                  for I in Pos + 2 .. Rev'Last loop
                     if Rev (I) = '}' then
                        Close := I;
                        exit;
                     end if;
                  end loop;

                  if Close = 0 then
                     raise Ada.IO_Exceptions.Data_Error with "invalid revision suffix";
                  end if;

                  Current := Apply_Brace_Suffix
                    (Repo,
                     Objects,
                     Current,
                     Rev (Pos + 2 .. Close - 1));
                  Pos := Close + 1;
               end;
            elsif Pos = Rev'Last then
               Current := Parent_Commit (Repo, Objects, Current, 1);
               Pos := Pos + 1;
            elsif Rev (Pos + 1) in '0' .. '9' then
               declare
                  Start : constant Natural := Pos + 1;
                  Stop  : Natural := Start;
               begin
                  while Stop <= Rev'Last and then Rev (Stop) in '0' .. '9' loop
                     Stop := Stop + 1;
                  end loop;

                  declare
                     Parent_Index : constant Natural :=
                       Decimal_Value (Rev (Start .. Stop - 1));
                  begin
                     if Parent_Index = 0 then
                        raise Ada.IO_Exceptions.Data_Error with "invalid parent index";
                     end if;

                     Current := Parent_Commit (Repo, Objects, Current, Positive (Parent_Index));
                     Pos := Stop;
                  end;
               end;
            elsif Rev (Pos + 1) = '^' or else Rev (Pos + 1) = '~' then
               Current := Parent_Commit (Repo, Objects, Current, 1);
               Pos := Pos + 1;
            else
               raise Ada.IO_Exceptions.Data_Error with "invalid revision suffix";
            end if;

         elsif Rev (Pos) = '~' then
            declare
               Start : constant Natural := Pos + 1;
               Stop  : Natural := Start;
               Count : Natural;
            begin
               while Stop <= Rev'Last and then Rev (Stop) in '0' .. '9' loop
                  Stop := Stop + 1;
               end loop;

               Count :=
                 (if Stop = Start then 1 else Decimal_Value (Rev (Start .. Stop - 1)));

               for I in 1 .. Count loop
                  Current := Parent_Commit (Repo, Objects, Current, 1);
               end loop;

               Pos := Stop;
            end;
         else
            raise Ada.IO_Exceptions.Data_Error with "invalid revision suffix";
         end if;
      end loop;

      case Kind is
         when Any_Object =>
            declare
               Obj : constant Version.Objects.Git_Object :=
                 Version.Object_Cache.Read_Object (Repo, Objects, Current);
            begin
               if Version.Objects.Kind (Obj) = Version.Objects.Unknown_Object then
                  raise Ada.IO_Exceptions.Data_Error with
                    "unknown object kind: " & To_String (Current);
               end if;

               return Current;
            end;
         when Commitish =>
            return Require_Commit (Repo, Objects, Current);
         when Treeish =>
            return To_Tree (Repo, Objects, Current);
      end case;
   end Resolve;

   function Resolve_Commit
     (Repo : Version.Repository.Repository_Handle;
      Text : String)
      return Version.Objects.Hex_Object_Id is
   begin
      return Resolve (Repo, Text, Commitish);
   end Resolve_Commit;

   function Resolve_Tree
     (Repo : Version.Repository.Repository_Handle;
      Text : String)
      return Version.Objects.Hex_Object_Id is
   begin
      return Resolve (Repo, Text, Treeish);
   end Resolve_Tree;

end Version.Revisions;
