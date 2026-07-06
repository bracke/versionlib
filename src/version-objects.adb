with Ada.IO_Exceptions;
with Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Directories;

with Version.Files;
with Version.Compression;
with Version.Pack;
with Version.Path_Safety;
with Version.Promisor;

package body Version.Objects is

   use Ada.Streams;

   function To_String (Id : Object_Id_Storage) return String is
     (Id.Text (1 .. Id.Length));

   function To_Object_Id (Text : String) return Object_Id_Storage is
      Result : Object_Id_Storage;
   begin
      Result.Length := Text'Length;
      Result.Text (1 .. Text'Length) := Text;
      return Result;
   end To_Object_Id;

   function Zero_Object_Id return Object_Id_Storage is
     (To_Object_Id ([1 .. 40 => '0']));

   function Id_Length (Id : Object_Id_Storage) return Natural is (Id.Length);

   function "<" (Left, Right : Object_Id_Storage) return Boolean is
     (To_String (Left) < To_String (Right));

   function "=" (Left : Object_Id_Storage; Right : String) return Boolean is
     (To_String (Left) = Right);

   function "=" (Left : String; Right : Object_Id_Storage) return Boolean is
     (Left = To_String (Right));

   function Is_Hex_Digit (C : Character) return Boolean is
   begin
      return
        (C >= '0' and then C <= '9')
        or else (C >= 'a' and then C <= 'f')
        or else (C >= 'A' and then C <= 'F');
   end Is_Hex_Digit;

   function Is_Valid_Hex_Object_Id (Value : String) return Boolean is
   begin
      --  A full object id is 40 hex chars (SHA-1) or 64 (SHA-256). Callers
      --  that know the repo's algorithm can tighten this; here we accept
      --  either width so sha256 refs/ids validate once the format is enabled.
      if Value'Length /= 40 and then Value'Length /= 64 then
         return False;
      end if;

      for C of Value loop
         if not Is_Hex_Digit (C) then
            return False;
         end if;
      end loop;

      return True;
   end Is_Valid_Hex_Object_Id;

   function Join (Left, Right : String) return String
   renames Version.Files.Join;

   function Loose_Object_Path
     (Repo : Version.Repository.Repository_Handle; Id : Hex_Object_Id)
      return String
   is
      Dir  : constant String := To_String (Id) (1 .. 2);
      File : constant String := To_String (Id) (3 .. To_String (Id)'Last);
   begin
      return
        Join
          (Join
             (Join (Version.Repository.Common_Git_Dir (Repo), "objects"), Dir),
           File);
   end Loose_Object_Path;

   function Read_File_As_String (Path : String) return String is
      File : Stream_IO.File_Type;
   begin
      Stream_IO.Open
        (File, Stream_IO.In_File, Version.Files.To_Native_Path (Path));

      declare
         Size   : constant Stream_IO.Count := Stream_IO.Size (File);
         Data   : Stream_Element_Array (1 .. Stream_Element_Offset (Size));
         Last   : Stream_Element_Offset;
         Result : String (1 .. Integer (Size));
      begin
         Stream_IO.Read (File, Data, Last);
         Stream_IO.Close (File);

         if Last /= Data'Last then
            raise Ada.IO_Exceptions.Data_Error
              with "could not read complete object file";
         end if;

         for I in Data'Range loop
            Result (Integer (I)) := Character'Val (Data (I));
         end loop;

         return Result;
      end;

   exception
      when others =>
         if Stream_IO.Is_Open (File) then
            Stream_IO.Close (File);
         end if;

         raise;
   end Read_File_As_String;

   function Lower_Hex (Value : String) return String is
      Result : String (Value'Range);
   begin
      for I in Value'Range loop
         if Value (I) in 'A' .. 'F' then
            Result (I) :=
              Character'Val
                (Character'Pos (Value (I))
                 - Character'Pos ('A')
                 + Character'Pos ('a'));
         else
            Result (I) := Value (I);
         end if;
      end loop;

      return Result;
   end Lower_Hex;

   function Parse_Object_Size (Text : String) return Natural is
      Result : Natural := 0;
   begin
      if Text'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error
           with "corrupt object: missing declared size";
      end if;

      for C of Text loop
         if C not in '0' .. '9' then
            raise Ada.IO_Exceptions.Data_Error
              with "corrupt object: invalid declared size";
         end if;

         Result := Result * 10 + Character'Pos (C) - Character'Pos ('0');
      end loop;

      return Result;
   end Parse_Object_Size;

   function Create_Object
     (Kind : Object_Kind; Content : String) return Git_Object is
   begin
      return
        (Kind_Value => Kind, Content_Value => To_Unbounded_String (Content));
   end Create_Object;
   function Read_Loose_Object
     (Repo : Version.Repository.Repository_Handle; Id : Hex_Object_Id)
      return Git_Object
   is
      Path       : constant String := Loose_Object_Path (Repo, Id);
      Compressed : constant String := Read_File_As_String (Path);
      Raw        : constant String :=
        Version.Compression.Inflate_Zlib (Compressed);

      Nul_Pos : Natural := 0;
   begin
      for I in Raw'Range loop
         if Raw (I) = Character'Val (0) then
            Nul_Pos := I;
            exit;
         end if;
      end loop;

      if Nul_Pos = 0 then
         raise Ada.IO_Exceptions.Data_Error
           with "corrupt object: missing object header terminator";
      end if;

      declare
         Header    : constant String := Raw (Raw'First .. Nul_Pos - 1);
         Payload   : constant String := Raw (Nul_Pos + 1 .. Raw'Last);
         Space_Pos : Natural := 0;
      begin
         if Lower_Hex (To_String (Id)) /=
           Version.Hash.Object_Hash_Hex
             (Version.Repository.Algorithm (Repo), Raw)
         then
            raise Ada.IO_Exceptions.Data_Error
              with "corrupt object: hash mismatch";
         end if;

         for I in Header'Range loop
            if Header (I) = ' ' then
               Space_Pos := I;
               exit;
            end if;
         end loop;

         if Space_Pos = 0 then
            raise Ada.IO_Exceptions.Data_Error
              with "corrupt object: missing type/size separator";
         end if;

         declare
            Kind_Text     : constant String :=
              Header (Header'First .. Space_Pos - 1);
            Size_Text     : constant String :=
              Header (Space_Pos + 1 .. Header'Last);
            Declared_Size : constant Natural := Parse_Object_Size (Size_Text);
         begin
            if Payload'Length /= Declared_Size then
               raise Ada.IO_Exceptions.Data_Error
                 with "corrupt object: declared size mismatch";
            end if;

            if Kind_Text = "blob" then
               return
                 (Kind_Value    => Blob_Object,
                  Content_Value => To_Unbounded_String (Payload));

            elsif Kind_Text = "tree" then
               return
                 (Kind_Value    => Tree_Object,
                  Content_Value => To_Unbounded_String (Payload));

            elsif Kind_Text = "commit" then
               return
                 (Kind_Value    => Commit_Object,
                  Content_Value => To_Unbounded_String (Payload));

            elsif Kind_Text = "tag" then
               return
                 (Kind_Value    => Tag_Object,
                  Content_Value => To_Unbounded_String (Payload));

            else
               return
                 (Kind_Value    => Unknown_Object,
                  Content_Value => To_Unbounded_String (Payload));
            end if;
         end;
      end;
   end Read_Loose_Object;

   function Read_Object
     (Repo : Version.Repository.Repository_Handle; Id : Hex_Object_Id)
      return Git_Object
   is
      Path : constant String := Loose_Object_Path (Repo, Id);
   begin
      if Ada.Directories.Exists (Path) then
         return Read_Loose_Object (Repo, Id);
      end if;

      if Version.Pack.Contains (Repo, Id) then
         return Version.Pack.Read_Object (Repo, Id);
      end if;

      if Version.Promisor.Fetch_Promised_Object (Repo, To_String (Id)) then
         if Ada.Directories.Exists (Path) then
            return Read_Loose_Object (Repo, Id);
         end if;

         if Version.Pack.Contains (Repo, Id) then
            return Version.Pack.Read_Object (Repo, Id);
         end if;
      end if;

      raise Ada.IO_Exceptions.Data_Error with
        Version.Promisor.Missing_Object_Diagnostic (Repo, To_String (Id));
   end Read_Object;

   function To_Hex (Bytes : String) return Hex_Object_Id is
      Hex    : constant String := "0123456789abcdef";
      Result : String (1 .. Bytes'Length * 2);
      Pos    : Natural := 1;
   begin
      if Bytes'Length /= 20 and then Bytes'Length /= 32 then
         raise Ada.IO_Exceptions.Data_Error
           with "invalid raw object id length";
      end if;

      for C of Bytes loop
         declare
            V : constant Natural := Character'Pos (C);
         begin
            Result (Pos) := Hex ((V / 16) + 1);
            Result (Pos + 1) := Hex ((V mod 16) + 1);
            Pos := Pos + 2;
         end;
      end loop;

      return To_Object_Id (Result);
   end To_Hex;

   function To_Raw (Id : Object_Id_Storage) return String is
      Hex_Text : constant String := To_String (Id);
      Result   : String (1 .. Hex_Text'Length / 2);
      Pos      : Positive := Hex_Text'First;

      function Nibble (C : Character) return Natural is
      begin
         if C in '0' .. '9' then
            return Character'Pos (C) - Character'Pos ('0');
         elsif C in 'a' .. 'f' then
            return Character'Pos (C) - Character'Pos ('a') + 10;
         elsif C in 'A' .. 'F' then
            return Character'Pos (C) - Character'Pos ('A') + 10;
         else
            raise Ada.IO_Exceptions.Data_Error
              with "invalid object id hex digit";
         end if;
      end Nibble;
   begin
      for I in Result'Range loop
         Result (I) :=
           Character'Val (Nibble (Hex_Text (Pos)) * 16 + Nibble (Hex_Text (Pos + 1)));
         Pos := Pos + 2;
      end loop;

      return Result;
   end To_Raw;

   function Compute_Object_Id
     (Algorithm : Version.Hash.Hash_Algorithm;
      Kind      : String;
      Content   : String)
      return Hex_Object_Id
   is
      Header : constant String :=
        Kind & Natural'Image (Content'Length) & Character'Val (0);
   begin
      return
        To_Object_Id
          (Version.Hash.Object_Hash_Hex (Algorithm, Header & Content));
   end Compute_Object_Id;

   function Commit_Tree_Id (Obj : Git_Object) return Hex_Object_Id is
      Text   : constant String := To_String (Obj.Content_Value);
      Prefix : constant String := "tree ";
   begin
      if Obj.Kind_Value /= Commit_Object then
         raise Ada.IO_Exceptions.Data_Error with "object is not a commit";
      end if;

      if Text'Length < Prefix'Length
        or else Text (Text'First .. Text'First + Prefix'Length - 1) /= Prefix
      then
         raise Ada.IO_Exceptions.Data_Error
           with "corrupt commit: first line is not tree";
      end if;

      declare
         --  The tree id runs from after "tree " to the end of the first line;
         --  its width (40 or 64 hex) is validated, not assumed.
         Line_End : Natural := Text'First + Prefix'Length;
      begin
         while Line_End <= Text'Last
           and then Text (Line_End) /= Character'Val (10)
         loop
            Line_End := Line_End + 1;
         end loop;

         declare
            Id : constant String :=
              Text (Text'First + Prefix'Length .. Line_End - 1);
         begin
            if not Is_Valid_Hex_Object_Id (Id) then
               raise Ada.IO_Exceptions.Data_Error
                 with "corrupt commit: invalid tree id";
            end if;

            return To_Object_Id (Id);
         end;
      end;
   end Commit_Tree_Id;

   function Commit_Parent_Ids
     (Obj : Git_Object) return Object_Id_Vectors.Vector
   is
      Result  : Object_Id_Vectors.Vector;
      Content : constant String := To_String (Obj.Content_Value);
      Start   : Natural := Content'First;
   begin
      while Start <= Content'Last loop
         declare
            Stop : Natural := Start;
         begin
            while Stop <= Content'Last
              and then Content (Stop) /= Character'Val (10)
            loop
               Stop := Stop + 1;
            end loop;

            declare
               Line : constant String := Content (Start .. Stop - 1);

               Prefix : constant String := "parent ";
            begin
               --  Parent lines only appear in the header; the blank line ends
               --  it, so stop there (a body line starting with "parent " is
               --  not a parent).
               exit when Line'Length = 0;

               if Line'Length > Prefix'Length
                 and then
                   Line (Line'First .. Line'First + Prefix'Length - 1) = Prefix
               then
                  declare
                     --  Id runs to end of line; width (40/64) is validated.
                     Id_Text : constant String :=
                       Line (Line'First + Prefix'Length .. Line'Last);
                  begin
                     if not Is_Valid_Hex_Object_Id (Id_Text) then
                        raise Ada.IO_Exceptions.Data_Error
                          with "corrupt commit: invalid parent id";
                     end if;

                     Result.Append (To_Object_Id (Id_Text));
                  end;
               end if;
            end;

            Start := Stop + 1;
         end;
      end loop;

      return Result;
   end Commit_Parent_Ids;
   function Commit_Parent_Id (Obj : Git_Object) return String is
      Parents : constant Object_Id_Vectors.Vector := Commit_Parent_Ids (Obj);
   begin
      if Parents.Is_Empty then
         return "";
      end if;

      return To_String (Parents.First_Element);
   end Commit_Parent_Id;

   function Tag_Target_Id (Obj : Git_Object) return Hex_Object_Id is
      Text   : constant String := To_String (Obj.Content_Value);
      Prefix : constant String := "object ";
   begin
      if Obj.Kind_Value /= Tag_Object then
         raise Ada.IO_Exceptions.Data_Error with "object is not a tag";
      end if;

      if Text'Length < Prefix'Length
        or else Text (Text'First .. Text'First + Prefix'Length - 1) /= Prefix
      then
         raise Ada.IO_Exceptions.Data_Error
           with "corrupt tag: first line is not object";
      end if;

      declare
         Line_End : Natural := Text'First + Prefix'Length;
      begin
         while Line_End <= Text'Last
           and then Text (Line_End) /= Character'Val (10)
         loop
            Line_End := Line_End + 1;
         end loop;

         declare
            Id_Text : constant String :=
              Text (Text'First + Prefix'Length .. Line_End - 1);
         begin
            if not Is_Valid_Hex_Object_Id (Id_Text) then
               raise Ada.IO_Exceptions.Data_Error
                 with "corrupt tag: invalid object id";
            end if;

            return To_Object_Id (Id_Text);
         end;
      end;
   end Tag_Target_Id;

   function Commit_Message_First_Line (Obj : Git_Object) return String is
      Text : constant String := To_String (Obj.Content_Value);
      Pos  : Natural := Text'First;
   begin
      if Obj.Kind_Value /= Commit_Object then
         raise Ada.IO_Exceptions.Data_Error with "object is not a commit";
      end if;

      while Pos <= Text'Last loop
         if Text (Pos) = Character'Val (10) then
            if Pos < Text'Last and then Text (Pos + 1) = Character'Val (10)
            then
               declare
                  Msg_Start : constant Natural := Pos + 2;
                  Msg_End   : Natural := Msg_Start;
               begin
                  if Msg_Start > Text'Last then
                     return "";
                  end if;

                  while Msg_End <= Text'Last
                    and then Text (Msg_End) /= Character'Val (10)
                  loop
                     Msg_End := Msg_End + 1;
                  end loop;

                  if Msg_End > Text'Last then
                     return Text (Msg_Start .. Text'Last);
                  else
                     return Text (Msg_Start .. Msg_End - 1);
                  end if;
               end;
            end if;
         end if;

         Pos := Pos + 1;
      end loop;

      return "";
   end Commit_Message_First_Line;

   procedure Append_Flattened_Tree
     (Repo      : Version.Repository.Repository_Handle;
      Tree_Id   : Hex_Object_Id;
      Base_Path : String;
      Result    : in out Tree_Entry_Vectors.Vector)
   is
      Obj  : constant Git_Object := Read_Object (Repo, Tree_Id);
      Data : constant String := To_String (Obj.Content_Value);
      Pos  : Natural := Data'First;
      Raw_Length : constant Natural :=
        Version.Hash.Raw_Length (Version.Repository.Algorithm (Repo));
   begin
      if Obj.Kind_Value /= Tree_Object then
         raise Ada.IO_Exceptions.Data_Error with "object is not a tree";
      end if;

      while Pos <= Data'Last loop
         declare
            Mode_Start : constant Natural := Pos;
            Mode_End   : Natural := 0;
            Name_Start : Natural;
            Name_End   : Natural := 0;
            E_Id       : Object_Id_Storage;
         begin
            while Pos <= Data'Last and then Data (Pos) /= ' ' loop
               Pos := Pos + 1;
            end loop;

            if Pos > Data'Last then
               raise Ada.IO_Exceptions.Data_Error
                 with "corrupt tree: missing mode terminator";
            end if;

            Mode_End := Pos - 1;
            Pos := Pos + 1;

            Name_Start := Pos;

            while Pos <= Data'Last and then Data (Pos) /= Character'Val (0)
            loop
               Pos := Pos + 1;
            end loop;

            if Pos > Data'Last then
               raise Ada.IO_Exceptions.Data_Error
                 with "corrupt tree: missing name terminator";
            end if;

            Name_End := Pos - 1;
            Pos := Pos + 1;

            if Pos + Raw_Length - 1 > Data'Last then
               raise Ada.IO_Exceptions.Data_Error
                 with "corrupt tree: truncated object id";
            end if;

            E_Id := To_Hex (Data (Pos .. Pos + Raw_Length - 1));
            Pos := Pos + Raw_Length;

            declare
               Mode_Text : constant String := Data (Mode_Start .. Mode_End);

               Name_Text : constant String := Data (Name_Start .. Name_End);

               Full_Path : constant String :=
                 (if Base_Path'Length = 0
                  then Name_Text
                  else Base_Path & "/" & Name_Text);
            begin
               Version.Path_Safety.Require_Safe_Relative_Path
                 (Full_Path, "tree entry path");

               if Mode_Text = "40000" then
                  Append_Flattened_Tree
                    (Repo      => Repo,
                     Tree_Id   => E_Id,
                     Base_Path => Full_Path,
                     Result    => Result);
               elsif Mode_Text = "160000" then
                  Result.Append
                    (Tree_Entry'
                       (Path => To_Unbounded_String (Full_Path),
                        Id   => E_Id,
                        Kind => Tree_Gitlink,
                        Mode => To_Unbounded_String (Mode_Text)));
               else
                  Result.Append
                    (Tree_Entry'
                       (Path => To_Unbounded_String (Full_Path),
                        Id   => E_Id,
                        Kind => Tree_Blob,
                        Mode => To_Unbounded_String (Mode_Text)));
               end if;
            end;
         end;
      end loop;
   end Append_Flattened_Tree;

   function Flatten_Tree
     (Repo : Version.Repository.Repository_Handle; Tree_Id : Hex_Object_Id)
      return Tree_Entry_Vectors.Vector
   is
      Result : Tree_Entry_Vectors.Vector;
   begin
      Append_Flattened_Tree
        (Repo => Repo, Tree_Id => Tree_Id, Base_Path => "", Result => Result);

      return Result;
   end Flatten_Tree;

   function Parse_Tree
     (Algorithm : Version.Hash.Hash_Algorithm;
      Data      : String)
      return Tree_Entry_Vectors.Vector
   is
      Raw_Length : constant Natural := Version.Hash.Raw_Length (Algorithm);
      Pos        : Natural := Data'First;
      Result     : Tree_Entry_Vectors.Vector;
   begin
      while Pos <= Data'Last loop
         declare
            Mode_Start : constant Natural := Pos;
            Mode_End   : Natural := 0;
            Name_Start : Natural;
            Name_End   : Natural := 0;
            E_Id       : Object_Id_Storage;
         begin
            while Pos <= Data'Last and then Data (Pos) /= ' ' loop
               Pos := Pos + 1;
            end loop;
            if Pos > Data'Last then
               raise Ada.IO_Exceptions.Data_Error
                 with "corrupt tree: missing mode terminator";
            end if;
            Mode_End := Pos - 1;
            Pos := Pos + 1;

            Name_Start := Pos;
            while Pos <= Data'Last and then Data (Pos) /= Character'Val (0) loop
               Pos := Pos + 1;
            end loop;
            if Pos > Data'Last then
               raise Ada.IO_Exceptions.Data_Error
                 with "corrupt tree: missing name terminator";
            end if;
            Name_End := Pos - 1;
            Pos := Pos + 1;

            if Pos + Raw_Length - 1 > Data'Last then
               raise Ada.IO_Exceptions.Data_Error
                 with "corrupt tree: truncated object id";
            end if;
            E_Id := To_Hex (Data (Pos .. Pos + Raw_Length - 1));
            Pos := Pos + Raw_Length;

            declare
               Mode_Text : constant String := Data (Mode_Start .. Mode_End);
               Name_Text : constant String := Data (Name_Start .. Name_End);
            begin
               Version.Path_Safety.Require_Safe_Relative_Path
                 (Name_Text, "tree entry path");
               Result.Append
                 (Tree_Entry'
                    (Path => To_Unbounded_String (Name_Text),
                     Id   => E_Id,
                     Kind => (if Mode_Text = "40000" then Tree_Directory
                              elsif Mode_Text = "160000" then Tree_Gitlink
                              else Tree_Blob),
                     Mode => To_Unbounded_String (Mode_Text)));
            end;
         end;
      end loop;

      return Result;
   end Parse_Tree;

   function Tree_Entries
     (Repo    : Version.Repository.Repository_Handle;
      Tree_Id : Hex_Object_Id)
      return Tree_Entry_Vectors.Vector
   is
      Obj : constant Git_Object := Read_Object (Repo, Tree_Id);
   begin
      if Obj.Kind_Value /= Tree_Object then
         raise Ada.IO_Exceptions.Data_Error with "object is not a tree";
      end if;

      return
        Parse_Tree
          (Version.Repository.Algorithm (Repo), To_String (Obj.Content_Value));
   end Tree_Entries;

   function Kind (Obj : Git_Object) return Object_Kind is
   begin
      return Obj.Kind_Value;
   end Kind;

   function Content (Obj : Git_Object) return String is
   begin
      return To_String (Obj.Content_Value);
   end Content;

end Version.Objects;
