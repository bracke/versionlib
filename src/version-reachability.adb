with Ada.Containers.Ordered_Sets;
with Ada.Directories; use Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with Version.Hash;
with Version.Files;
with Version.Object_Cache;
with Version.Merge;
with Version.Merge_State;
with Version.Packed_Refs;
with Version.Refs;
with Version.Shallow_Cache;
with Version.Transport.Local;

package body Version.Reachability is
   use Version.Objects;

   use Ada.Strings.Unbounded;

   function Join (Left, Right : String) return String
   renames Version.Files.Join;

   package Object_Id_Sets is new
     Ada.Containers.Ordered_Sets
       (Element_Type => Version.Objects.Object_Id_Storage);

   function Starts_With (Value, Prefix : String) return Boolean is
   begin
      return
        Value'Length >= Prefix'Length
        and then
          Value (Value'First .. Value'First + Prefix'Length - 1) = Prefix;
   end Starts_With;

   function Ends_With (Value, Suffix : String) return Boolean is
   begin
      return
        Value'Length >= Suffix'Length
        and then
          Value (Value'Last - Suffix'Length + 1 .. Value'Last) = Suffix;
   end Ends_With;

   function Is_Zero (Id : Version.Objects.Hex_Object_Id) return Boolean is
   begin
      for C of To_String (Id) loop
         if C /= '0' then
            return False;
         end if;
      end loop;

      return True;
   end Is_Zero;

   function Contains
     (Items : Version.Objects.Object_Id_Vectors.Vector;
      Id    : Version.Objects.Hex_Object_Id) return Boolean is
   begin
      if Items.Is_Empty then
         return False;
      end if;

      for I in Items.First_Index .. Items.Last_Index loop
         if Items.Element (I) = Id then
            return True;
         end if;
      end loop;

      return False;
   end Contains;

   procedure Append_Unique
     (Items : in out Version.Objects.Object_Id_Vectors.Vector;
      Id    : Version.Objects.Hex_Object_Id) is
   begin
      if not Is_Zero (Id) and then not Contains (Items, Id) then
         Items.Append (Id);
      end if;
   end Append_Unique;

   procedure Append_Unique
     (Items : in out Version.Objects.Object_Id_Vectors.Vector;
      Seen  : in out Object_Id_Sets.Set;
      Id    : Version.Objects.Hex_Object_Id) is
   begin
      if not Is_Zero (Id) and then not Seen.Contains (Id) then
         Items.Append (Id);
         Seen.Include (Id);
      end if;
   end Append_Unique;

   procedure Append_Refs_In_Directory
     (Base_Dir : String;
      Prefix   : String;
      Result   : in out Version.Objects.Object_Id_Vectors.Vector)
   is
      Search    : Ada.Directories.Search_Type;
      Dir_Entry : Ada.Directories.Directory_Entry_Type;
      Opened    : Boolean := False;
   begin
      if not Ada.Directories.Exists (Base_Dir) then
         return;
      end if;

      Ada.Directories.Start_Search
        (Search    => Search,
         Directory => Base_Dir,
         Pattern   => "*",
         Filter    =>
           [Ada.Directories.Ordinary_File => True,
            Ada.Directories.Directory     => True,
            Ada.Directories.Special_File  => False]);
      Opened := True;

      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Dir_Entry);

         declare
            Name : constant String := Ada.Directories.Simple_Name (Dir_Entry);
            Full : constant String := Ada.Directories.Full_Name (Dir_Entry);
         begin
            if Name /= "." and then Name /= ".." then
               if Ada.Directories.Kind (Dir_Entry) = Ada.Directories.Directory
               then
                  Append_Refs_In_Directory
                    (Base_Dir => Full,
                     Prefix   =>
                       (if Prefix'Length = 0
                        then Name
                        else Prefix & "/" & Name),
                     Result   => Result);
               elsif Ada.Directories.Kind (Dir_Entry)
                 = Ada.Directories.Ordinary_File
               then
                  if not Ends_With (Name, ".lock") then
                     declare
                        File : Ada.Text_IO.File_Type;
                     begin
                        Ada.Text_IO.Open
                          (File,
                           Ada.Text_IO.In_File,
                           Version.Files.To_Native_Path (Full));
                        if not Ada.Text_IO.End_Of_File (File) then
                           declare
                              Line : constant String :=
                                Ada.Strings.Fixed.Trim
                                  (Ada.Text_IO.Get_Line (File), Ada.Strings.Both);
                           begin
                              if Version.Objects.Is_Valid_Hex_Object_Id (Line)
                              then
                                 Append_Unique
                                   (Result, Version.Objects.To_Object_Id (Line));
                              elsif Line'Length > 0 then
                                 raise Ada.IO_Exceptions.Data_Error
                                   with "invalid ref object id: "
                                     & Prefix & "/" & Name;
                              end if;
                           end;
                        end if;
                        Ada.Text_IO.Close (File);
                     exception
                        when others =>
                           if Ada.Text_IO.Is_Open (File) then
                              Ada.Text_IO.Close (File);
                           end if;
                           raise;
                     end;
                  end if;
               end if;
            end if;
         end;
      end loop;

      Ada.Directories.End_Search (Search);
   exception
      when others =>
         if Opened then
            Ada.Directories.End_Search (Search);
         end if;
         raise;
   end Append_Refs_In_Directory;

   procedure Append_Reflog_File
     (Path : String; Result : in out Version.Objects.Object_Id_Vectors.Vector)
   is
      File : Ada.Text_IO.File_Type;
   begin
      Ada.Text_IO.Open
        (File, Ada.Text_IO.In_File, Version.Files.To_Native_Path (Path));

      while not Ada.Text_IO.End_Of_File (File) loop
         declare
            Line : constant String := Ada.Text_IO.Get_Line (File);
            --  Reflog line: "<old> <new> <who>\t<msg>". old/new are the first
            --  two space-separated hex ids (40 or 64), so split on spaces
            --  rather than assuming a width.
            First_Space  : Natural := 0;
            Second_Space : Natural := 0;
         begin
            if Line'Length > 0 then
               for I in Line'Range loop
                  if Line (I) = ' ' then
                     if First_Space = 0 then
                        First_Space := I;
                     else
                        Second_Space := I;
                        exit;
                     end if;
                  end if;
               end loop;

               if First_Space = 0 or else Second_Space = 0 then
                  raise Ada.IO_Exceptions.Data_Error
                    with "malformed reflog: " & Path;
               end if;

               declare
                  Old_Id : constant String :=
                    Line (Line'First .. First_Space - 1);
                  New_Id : constant String :=
                    Line (First_Space + 1 .. Second_Space - 1);
               begin
                  if not Version.Objects.Is_Valid_Hex_Object_Id (Old_Id)
                    or else not Version.Objects.Is_Valid_Hex_Object_Id (New_Id)
                  then
                     raise Ada.IO_Exceptions.Data_Error
                       with "malformed reflog: " & Path;
                  end if;

                  Append_Unique
                    (Result, Version.Objects.To_Object_Id (Old_Id));
                  Append_Unique
                    (Result, Version.Objects.To_Object_Id (New_Id));
               end;
            end if;
         end;
      end loop;

      Ada.Text_IO.Close (File);
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         raise;
   end Append_Reflog_File;

   procedure Append_Reflogs_In_Directory
     (Base_Dir : String;
      Result   : in out Version.Objects.Object_Id_Vectors.Vector)
   is
      Search    : Ada.Directories.Search_Type;
      Dir_Entry : Ada.Directories.Directory_Entry_Type;
      Opened    : Boolean := False;
   begin
      if not Ada.Directories.Exists (Base_Dir) then
         return;
      end if;

      Ada.Directories.Start_Search
        (Search    => Search,
         Directory => Base_Dir,
         Pattern   => "*",
         Filter    =>
           [Ada.Directories.Ordinary_File => True,
            Ada.Directories.Directory     => True,
            Ada.Directories.Special_File  => False]);
      Opened := True;

      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Dir_Entry);

         declare
            Name : constant String := Ada.Directories.Simple_Name (Dir_Entry);
            Full : constant String := Ada.Directories.Full_Name (Dir_Entry);
         begin
            if Name /= "." and then Name /= ".." then
               if Ada.Directories.Kind (Dir_Entry) = Ada.Directories.Directory
               then
                  Append_Reflogs_In_Directory (Full, Result);
               elsif Ada.Directories.Kind (Dir_Entry)
                 = Ada.Directories.Ordinary_File
               then
                  if not Ends_With (Name, ".lock") then
                     Append_Reflog_File (Full, Result);
                  end if;
               end if;
            end if;
         end;
      end loop;

      Ada.Directories.End_Search (Search);
   exception
      when others =>
         if Opened then
            Ada.Directories.End_Search (Search);
         end if;
         raise;
   end Append_Reflogs_In_Directory;

   procedure Append_Hex_Ids_From_File
     (Path : String; Result : in out Version.Objects.Object_Id_Vectors.Vector)
   is
      File : Ada.Text_IO.File_Type;

      procedure Scan_Token (Token : String) is
      begin
         if Version.Objects.Is_Valid_Hex_Object_Id (Token) then
            Append_Unique (Result, Version.Objects.To_Object_Id (Token));
         end if;
      end Scan_Token;

      procedure Scan_Line (Line : String) is
         First : Natural := Line'First;
      begin
         while First <= Line'Last loop
            while First <= Line'Last and then Line (First) = ' ' loop
               First := First + 1;
            end loop;

            exit when First > Line'Last;

            declare
               Last : Natural := First;
            begin
               while Last <= Line'Last and then Line (Last) /= ' ' loop
                  Last := Last + 1;
               end loop;

               Scan_Token (Line (First .. Last - 1));
               First := Last + 1;
            end;
         end loop;
      end Scan_Line;
   begin
      if not Ada.Directories.Exists (Path)
        or else Ada.Directories.Kind (Path) /= Ada.Directories.Ordinary_File
      then
         return;
      end if;

      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);
      while not Ada.Text_IO.End_Of_File (File) loop
         Scan_Line (Ada.Text_IO.Get_Line (File));
      end loop;
      Ada.Text_IO.Close (File);
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
   end Append_Hex_Ids_From_File;

   procedure Append_Worktree_State_Roots
     (Git_Dir : String;
      Result  : in out Version.Objects.Object_Id_Vectors.Vector) is
   begin
      Append_Hex_Ids_From_File (Join (Git_Dir, "VERSION_MERGE"), Result);
      Append_Hex_Ids_From_File (Join (Git_Dir, "VERSION_REBASE"), Result);
      Append_Hex_Ids_From_File (Join (Git_Dir, "VERSION_CHERRY_PICK"), Result);
      Append_Hex_Ids_From_File (Join (Git_Dir, "VERSION_REVERT"), Result);
   end Append_Worktree_State_Roots;

   procedure Append_Worktree_HEAD_Reflog_Roots
     (Git_Dir : String;
      Result  : in out Version.Objects.Object_Id_Vectors.Vector)
   is
      Log_Path : constant String := Join (Join (Git_Dir, "logs"), "HEAD");
   begin
      if Ada.Directories.Exists (Log_Path)
        and then Ada.Directories.Kind (Log_Path) = Ada.Directories.Ordinary_File
      then
         Append_Reflog_File (Log_Path, Result);
      end if;
   end Append_Worktree_HEAD_Reflog_Roots;

   procedure Append_Linked_Worktree_HEAD_Reflogs
     (Repo   : Version.Repository.Repository_Handle;
      Result : in out Version.Objects.Object_Id_Vectors.Vector)
   is
      Root      : constant String :=
        Join (Version.Repository.Common_Git_Dir (Repo), "worktrees");
      Search    : Ada.Directories.Search_Type;
      Dir_Entry : Ada.Directories.Directory_Entry_Type;
      Opened    : Boolean := False;
   begin
      if not Ada.Directories.Exists (Root) then
         return;
      end if;

      Ada.Directories.Start_Search
        (Search    => Search,
         Directory => Root,
         Pattern   => "*",
         Filter    =>
           [Ada.Directories.Ordinary_File => False,
            Ada.Directories.Directory     => True,
            Ada.Directories.Special_File  => False]);
      Opened := True;

      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Dir_Entry);
         declare
            Name : constant String := Ada.Directories.Simple_Name (Dir_Entry);
         begin
            if Name /= "." and then Name /= ".." then
               Append_Worktree_HEAD_Reflog_Roots
                 (Git_Dir => Ada.Directories.Full_Name (Dir_Entry),
                  Result  => Result);
            end if;
         end;
      end loop;

      Ada.Directories.End_Search (Search);
   exception
      when others =>
         if Opened then
            Ada.Directories.End_Search (Search);
         end if;
         raise;
   end Append_Linked_Worktree_HEAD_Reflogs;

   function Reflog_Roots
     (Repo : Version.Repository.Repository_Handle)
      return Version.Objects.Object_Id_Vectors.Vector
   is
      Result : Version.Objects.Object_Id_Vectors.Vector;
      Logs   : constant String :=
        Join (Version.Repository.Common_Git_Dir (Repo), "logs");
   begin
      Append_Reflogs_In_Directory (Logs, Result);
      Append_Linked_Worktree_HEAD_Reflogs (Repo, Result);
      return Result;
   end Reflog_Roots;

   procedure Append_Linked_Worktree_HEADs
     (Repo   : Version.Repository.Repository_Handle;
      Result : in out Version.Objects.Object_Id_Vectors.Vector)
   is
      Root      : constant String :=
        Join (Version.Repository.Common_Git_Dir (Repo), "worktrees");
      Search    : Ada.Directories.Search_Type;
      Dir_Entry : Ada.Directories.Directory_Entry_Type;
      Opened    : Boolean := False;
   begin
      if not Ada.Directories.Exists (Root) then
         return;
      end if;

      Ada.Directories.Start_Search
        (Search    => Search,
         Directory => Root,
         Pattern   => "*",
         Filter    =>
           [Ada.Directories.Ordinary_File => False,
            Ada.Directories.Directory     => True,
            Ada.Directories.Special_File  => False]);
      Opened := True;

      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Dir_Entry);
         declare
            Name      : constant String :=
              Ada.Directories.Simple_Name (Dir_Entry);
            Head_Path : constant String :=
              Join (Ada.Directories.Full_Name (Dir_Entry), "HEAD");
         begin
            if Name /= "."
              and then Name /= ".."
              and then Ada.Directories.Exists (Head_Path)
              and then
                Ada.Directories.Kind (Head_Path)
                = Ada.Directories.Ordinary_File
            then
               declare
                  Line : constant String :=
                    Ada.Strings.Fixed.Trim
                      (Version.Transport.Local.Read_First_Line (Head_Path),
                       Ada.Strings.Both);
               begin
                  if Version.Objects.Is_Valid_Hex_Object_Id (Line) then
                     Append_Unique
                       (Result, Version.Objects.To_Object_Id (Line));
                  end if;
                  Append_Worktree_State_Roots
                    (Git_Dir => Ada.Directories.Full_Name (Dir_Entry),
                     Result  => Result);
               end;
            elsif Name /= "." and then Name /= ".." then
               Append_Worktree_State_Roots
                 (Git_Dir => Ada.Directories.Full_Name (Dir_Entry),
                  Result  => Result);
            end if;
         end;
      end loop;

      Ada.Directories.End_Search (Search);
   exception
      when others =>
         if Opened then
            Ada.Directories.End_Search (Search);
         end if;
         raise;
   end Append_Linked_Worktree_HEADs;

   function Repository_Roots
     (Repo : Version.Repository.Repository_Handle)
      return Version.Objects.Object_Id_Vectors.Vector
   is
      Result  : Version.Objects.Object_Id_Vectors.Vector;
      Head_Id : constant String := Version.Refs.Current_Commit_Id (Repo);
      Packed  : constant Version.Packed_Refs.Packed_Ref_Vectors.Vector :=
        Version.Packed_Refs.Read_All (Repo);
   begin
      if Version.Objects.Is_Valid_Hex_Object_Id (Head_Id) then
         Append_Unique (Result, Version.Objects.To_Object_Id (Head_Id));
      end if;

      Append_Worktree_State_Roots (Version.Repository.Git_Dir (Repo), Result);
      Append_Linked_Worktree_HEADs (Repo, Result);
      Append_Refs_In_Directory
        (Join (Version.Repository.Common_Git_Dir (Repo), "refs/heads"),
         "refs/heads",
         Result);
      Append_Refs_In_Directory
        (Join (Version.Repository.Common_Git_Dir (Repo), "refs/tags"),
         "refs/tags",
         Result);
      Append_Refs_In_Directory
        (Join (Version.Repository.Common_Git_Dir (Repo), "refs/remotes"),
         "refs/remotes",
         Result);

      if not Packed.Is_Empty then
         for I in Packed.First_Index .. Packed.Last_Index loop
            declare
               Name : constant String := To_String (Packed.Element (I).Name);
            begin
               if Starts_With (Name, "refs/heads/")
                 or else Starts_With (Name, "refs/tags/")
                 or else Starts_With (Name, "refs/remotes/")
               then
                  Append_Unique (Result, Packed.Element (I).Id);
               end if;
            end;
         end loop;
      end if;

      if Version.Merge_State.State_Exists (Repo) then
         declare
            Current_Id : Version.Objects.Object_Id_Storage;
            Target_Id  : Version.Objects.Object_Id_Storage;
            Base_Id    : Version.Objects.Object_Id_Storage;
            Target     : Ada.Strings.Unbounded.Unbounded_String;
            Conflicts  : Version.Merge.Conflict_Vectors.Vector;
         begin
            Version.Merge_State.Read_State
              (Repo          => Repo,
               Current_Id    => Current_Id,
               Target_Id     => Target_Id,
               Base_Id       => Base_Id,
               Target_Branch => Target,
               Conflicts     => Conflicts);
            Append_Unique (Result, Current_Id);
            Append_Unique (Result, Target_Id);
            Append_Unique (Result, Base_Id);
         exception
            when others =>
               declare
                  Target2 : Ada.Strings.Unbounded.Unbounded_String;
               begin
                  Version.Merge_State.Read_State
                    (Repo          => Repo,
                     Current_Id    => Current_Id,
                     Target_Id     => Target_Id,
                     Target_Branch => Target2);
                  Append_Unique (Result, Current_Id);
                  Append_Unique (Result, Target_Id);
               end;
         end;
      end if;

      declare
         Logs : constant Version.Objects.Object_Id_Vectors.Vector :=
           Reflog_Roots (Repo);
      begin
         if not Logs.Is_Empty then
            for I in Logs.First_Index .. Logs.Last_Index loop
               Append_Unique (Result, Logs.Element (I));
            end loop;
         end if;
      end;

      return Result;
   end Repository_Roots;

   procedure Append_Tree_Children
     (Repo        : Version.Repository.Repository_Handle;
      Tree        : Version.Objects.Git_Object;
      Pending     : in out Version.Objects.Object_Id_Vectors.Vector;
      Pending_Set : in out Object_Id_Sets.Set;
      Seen_Set    : Object_Id_Sets.Set)
   is
      Data : constant String := Version.Objects.Content (Tree);
      Pos  : Natural := Data'First;
      Raw_Length : constant Natural :=
        Version.Hash.Raw_Length (Version.Repository.Algorithm (Repo));
   begin
      while Pos <= Data'Last loop
         declare
            Mode_Start : constant Natural := Pos;
            Mode_End   : Natural := 0;
            Child_Id   : Version.Objects.Object_Id_Storage;
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
            while Pos <= Data'Last and then Data (Pos) /= Character'Val (0)
            loop
               Pos := Pos + 1;
            end loop;

            if Pos > Data'Last then
               raise Ada.IO_Exceptions.Data_Error
                 with "corrupt tree: missing name terminator";
            end if;

            Pos := Pos + 1;

            if Pos + Raw_Length - 1 > Data'Last then
               raise Ada.IO_Exceptions.Data_Error
                 with "corrupt tree: truncated object id";
            end if;

            Child_Id :=
              Version.Objects.To_Hex (Data (Pos .. Pos + Raw_Length - 1));
            Pos := Pos + Raw_Length;

            if Mode_End < Mode_Start then
               raise Ada.IO_Exceptions.Data_Error
                 with "corrupt tree: empty mode";
            end if;

            if not Seen_Set.Contains (Child_Id)
              and then not Pending_Set.Contains (Child_Id)
            then
               Pending.Append (Child_Id);
               Pending_Set.Include (Child_Id);
            end if;
         end;
      end loop;
   end Append_Tree_Children;

   function Reachable_From
     (Repo  : Version.Repository.Repository_Handle;
      Roots : Version.Objects.Object_Id_Vectors.Vector)
      return Version.Objects.Object_Id_Vectors.Vector
   is
      Seen        : Version.Objects.Object_Id_Vectors.Vector;
      Seen_Set    : Object_Id_Sets.Set;
      Pending     : Version.Objects.Object_Id_Vectors.Vector;
      Pending_Set : Object_Id_Sets.Set;
      Cursor      : Natural := 0;
      Objects     : Version.Object_Cache.Object_Cache;
      Shallow     : Version.Shallow_Cache.Shallow_Cache;
   begin
      if not Roots.Is_Empty then
         for I in Roots.First_Index .. Roots.Last_Index loop
            if not Is_Zero (Roots.Element (I))
              and then not Pending_Set.Contains (Roots.Element (I))
            then
               Pending.Append (Roots.Element (I));
               Pending_Set.Include (Roots.Element (I));
            end if;
         end loop;
      end if;

      if Pending.Is_Empty then
         return Seen;
      end if;

      Cursor := Pending.First_Index;

      while Cursor <= Pending.Last_Index loop
         declare
            Id : constant Version.Objects.Hex_Object_Id :=
              Pending.Element (Cursor);
         begin
            if not Seen_Set.Contains (Id) then
               Seen.Append (Id);
               Seen_Set.Include (Id);

               declare
                  Obj : constant Version.Objects.Git_Object :=
                    Version.Object_Cache.Read_Object (Repo, Objects, Id);
               begin
                  case Version.Objects.Kind (Obj) is
                     when Version.Objects.Commit_Object  =>
                        declare
                           Tree_Id : constant Version.Objects.Hex_Object_Id :=
                             Version.Objects.Commit_Tree_Id (Obj);
                           Parents :
                             constant Version
                                        .Objects
                                        .Object_Id_Vectors
                                        .Vector :=
                               Version.Objects.Commit_Parent_Ids (Obj);
                        begin
                           if not Seen_Set.Contains (Tree_Id)
                             and then not Pending_Set.Contains (Tree_Id)
                           then
                              Pending.Append (Tree_Id);
                              Pending_Set.Include (Tree_Id);
                           end if;

                           if not Version.Shallow_Cache.Is_Boundary
                                    (Repo, Shallow, Id)
                             and then not Parents.Is_Empty
                           then
                              for I in
                                Parents.First_Index .. Parents.Last_Index
                              loop
                                 if not Seen_Set.Contains (Parents.Element (I))
                                   and then
                                     not Pending_Set.Contains
                                           (Parents.Element (I))
                                 then
                                    Pending.Append (Parents.Element (I));
                                    Pending_Set.Include (Parents.Element (I));
                                 end if;
                              end loop;
                           end if;
                        end;

                     when Version.Objects.Tree_Object    =>
                        Append_Tree_Children
                          (Repo        => Repo,
                           Tree        => Obj,
                           Pending     => Pending,
                           Pending_Set => Pending_Set,
                           Seen_Set    => Seen_Set);

                     when Version.Objects.Tag_Object =>
                        declare
                           Target_Id : constant Version.Objects.Hex_Object_Id :=
                             Version.Objects.Tag_Target_Id (Obj);
                        begin
                           if not Seen_Set.Contains (Target_Id)
                             and then not Pending_Set.Contains (Target_Id)
                           then
                              Pending.Append (Target_Id);
                              Pending_Set.Include (Target_Id);
                           end if;
                        end;

                     when Version.Objects.Blob_Object
                        | Version.Objects.Unknown_Object =>
                        null;
                  end case;
               end;
            end if;

            Cursor := Cursor + 1;
         end;
      end loop;

      return Seen;
   end Reachable_From;

   function All_Loose_Objects
     (Repo : Version.Repository.Repository_Handle)
      return Version.Objects.Object_Id_Vectors.Vector
   is
      Result      : Version.Objects.Object_Id_Vectors.Vector;
      Seen        : Object_Id_Sets.Set;
      Objects_Dir : constant String :=
        Join (Version.Repository.Common_Git_Dir (Repo), "objects");
      Search      : Ada.Directories.Search_Type;
      Dir_Entry   : Ada.Directories.Directory_Entry_Type;
      Opened      : Boolean := False;
   begin
      if not Ada.Directories.Exists (Objects_Dir) then
         return Result;
      end if;

      Ada.Directories.Start_Search
        (Search    => Search,
         Directory => Objects_Dir,
         Pattern   => "*",
         Filter    =>
           [Ada.Directories.Ordinary_File => False,
            Ada.Directories.Directory     => True,
            Ada.Directories.Special_File  => False]);
      Opened := True;

      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Dir_Entry);

         declare
            Dir_Name : constant String :=
              Ada.Directories.Simple_Name (Dir_Entry);
            Dir_Full : constant String :=
              Ada.Directories.Full_Name (Dir_Entry);
         begin
            if Dir_Name'Length = 2
              and then
                Version.Objects.Is_Valid_Hex_Object_Id
                  (Dir_Name & [1 .. 38 => '0'])
            then
               declare
                  File_Search : Ada.Directories.Search_Type;
                  File_Entry  : Ada.Directories.Directory_Entry_Type;
                  File_Opened : Boolean := False;
               begin
                  Ada.Directories.Start_Search
                    (Search    => File_Search,
                     Directory => Dir_Full,
                     Pattern   => "*",
                     Filter    =>
                       [Ada.Directories.Ordinary_File => True,
                        Ada.Directories.Directory     => False,
                        Ada.Directories.Special_File  => False]);
                  File_Opened := True;

                  while Ada.Directories.More_Entries (File_Search) loop
                     Ada.Directories.Get_Next_Entry (File_Search, File_Entry);

                     declare
                        Name : constant String :=
                          Ada.Directories.Simple_Name (File_Entry);
                        Id   : constant String := Dir_Name & Name;
                     begin
                        if Name'Length = 38
                          and then Name (Name'Last - 4 .. Name'Last) /= ".lock"
                          and then Version.Objects.Is_Valid_Hex_Object_Id (Id)
                        then
                           Append_Unique
                             (Items => Result,
                              Seen  => Seen,
                              Id    => Version.Objects.To_Object_Id (Id));
                        end if;
                     end;
                  end loop;

                  Ada.Directories.End_Search (File_Search);
               exception
                  when others =>
                     if File_Opened then
                        Ada.Directories.End_Search (File_Search);
                     end if;
                     raise;
               end;
            end if;
         end;
      end loop;

      Ada.Directories.End_Search (Search);
      return Result;
   exception
      when others =>
         if Opened then
            Ada.Directories.End_Search (Search);
         end if;
         raise;
   end All_Loose_Objects;

end Version.Reachability;
