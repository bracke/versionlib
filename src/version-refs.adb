with Ada.Directories; use Ada.Directories;
with Ada.Strings.Fixed;
with Ada.IO_Exceptions;

with Version.Transport.Local;
with Version.Packed_Refs;
with Version.Files;
with Version.Ref_Names;
with Version.Reftable;
with Version.Reftable.Writer;

package body Version.Refs is
   use Version.Objects;

   Heads_Prefix : constant String := "refs/heads/";

   --  Replace or add one ref record in a reftable-backed repo, rewriting the
   --  table stack (incremental append + geometric compaction; see
   --  Version.Reftable.Writer).
   procedure Reftable_Put
     (Repo : Version.Repository.Repository_Handle;
      Rec  : Version.Reftable.Ref_Record)
   is
      Refs : Version.Reftable.Ref_Record_Vectors.Vector;
   begin
      Refs.Append (Rec);
      Version.Reftable.Writer.Append_Table (Repo, Refs);
   end Reftable_Put;

   --  Reads for a reftable-backed repository come from the binary table stack
   --  (Version.Reftable), not from loose files / packed-refs. The `.git/HEAD`
   --  file is a `refs/heads/.invalid` stub in this layout; the true HEAD is a
   --  symref record in the table.
   function Reftable_Read_Head
     (Repo : Version.Repository.Repository_Handle) return Head_Info
   is
      Found : Boolean;
      Rec   : constant Version.Reftable.Ref_Record :=
        Version.Reftable.Find (Repo, "HEAD", Found);
      use type Version.Reftable.Ref_Value_Kind;
   begin
      if Found and then Rec.Kind = Version.Reftable.Ref_Symref then
         declare
            Target : constant String := To_String (Rec.Target);
         begin
            if Target'Length < Heads_Prefix'Length
              or else Target (Target'First .. Target'First
                                + Heads_Prefix'Length - 1) /= Heads_Prefix
              or else not Version.Ref_Names.Is_Valid_Ref_Name (Target)
            then
               raise Ada.IO_Exceptions.Data_Error
                 with "unsupported repository: HEAD does not point to a branch";
            end if;
            return
              (Kind         => Attached_Branch,
               Branch_Value => To_Unbounded_String
                 (Target (Target'First + Heads_Prefix'Length .. Target'Last)));
         end;
      elsif Found then
         return
           (Kind         => Detached_Commit,
            Commit_Value => To_Unbounded_String (To_String (Rec.Id)));
      end if;

      raise Ada.IO_Exceptions.Data_Error with "invalid HEAD value";
   end Reftable_Read_Head;

   procedure Ensure_Parent_Directory (Path : String) is
   begin
      Version.Files.Create_Parent_Directories (Path);
   end Ensure_Parent_Directory;
   function Join (Left, Right : String) return String
   renames Version.Files.Join;

   function Contains (Value, Pattern : String) return Boolean is
   begin
      return Ada.Strings.Fixed.Index (Value, Pattern) /= 0;
   end Contains;

   procedure Validate_Atomic_Write_Path (Path : String) is
   begin
      if Path'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with "empty ref write path";
      end if;

      for C of Path loop
         if Character'Pos (C) < 32 or else Character'Pos (C) = 127 then
            raise Ada.IO_Exceptions.Data_Error
              with "ref write path contains control character";
         end if;
      end loop;

      if Contains (Path, "/../")
        or else Contains (Path, "/./")
        or else Contains (Path, "//")
      then
         raise Ada.IO_Exceptions.Data_Error
           with "unsafe ref write path: " & Path;
      end if;

      if Path'Length >= 5 and then Path (Path'Last - 4 .. Path'Last) = ".lock"
      then
         raise Ada.IO_Exceptions.Data_Error
           with "ref write target must not be a lockfile: " & Path;
      end if;
   end Validate_Atomic_Write_Path;

   function Read_Head
     (Repo : Version.Repository.Repository_Handle) return Head_Info
   is
      Head_Path : constant String :=
        Join (Version.Repository.Git_Dir (Repo), "HEAD");

      Line : constant String :=
        Ada.Strings.Fixed.Trim
          (Version.Transport.Local.Read_First_Line (Head_Path),
           Ada.Strings.Both);

      Ref_Prefix : constant String := "ref:";
   begin
      if Version.Reftable.Is_Reftable (Repo) then
         return Reftable_Read_Head (Repo);
      end if;

      if Line'Length >= Ref_Prefix'Length
        and then
          Line (Line'First .. Line'First + Ref_Prefix'Length - 1) = Ref_Prefix
      then
         declare
            Ref_Name : constant String :=
              Ada.Strings.Fixed.Trim
                (Line (Line'First + Ref_Prefix'Length .. Line'Last),
                 Ada.Strings.Both);

            Heads_Prefix : constant String := "refs/heads/";
         begin
            if Ref_Name'Length < Heads_Prefix'Length
              or else
                Ref_Name
                  (Ref_Name'First .. Ref_Name'First + Heads_Prefix'Length - 1)
                /= Heads_Prefix
              or else not Version.Ref_Names.Is_Valid_Ref_Name (Ref_Name)
            then
               raise Ada.IO_Exceptions.Data_Error
                 with
                   "unsupported repository: HEAD does not point to a branch";
            end if;

            return
              (Kind         => Attached_Branch,
               Branch_Value =>
                 To_Unbounded_String
                   (Ref_Name
                      (Ref_Name'First
                       + Heads_Prefix'Length
                       .. Ref_Name'Last)));
         end;
      end if;

      if not Version.Objects.Is_Valid_Hex_Object_Id (Line) then
         raise Ada.IO_Exceptions.Data_Error with "invalid HEAD value";
      end if;

      return
        (Kind => Detached_Commit, Commit_Value => To_Unbounded_String (Line));
   end Read_Head;

   function Resolve_Ref
     (Repo : Version.Repository.Repository_Handle; Name : String)
      return Version.Objects.Hex_Object_Id
   is
      Packed_Id : Version.Objects.Object_Id_Storage := Version.Objects.Zero_Object_Id;
   begin
      if not Version.Ref_Names.Is_Valid_Ref_Name (Name) then
         raise Ada.IO_Exceptions.Data_Error with "invalid ref name: " & Name;
      end if;

      if Version.Reftable.Is_Reftable (Repo) then
         declare
            Found : Boolean;
            Rec   : constant Version.Reftable.Ref_Record :=
              Version.Reftable.Find (Repo, Name, Found);
            use type Version.Reftable.Ref_Value_Kind;
         begin
            if not Found then
               raise Ada.IO_Exceptions.Data_Error
                 with "ref does not exist: " & Name;
            end if;
            if Rec.Kind = Version.Reftable.Ref_Symref then
               return Resolve_Ref (Repo, To_String (Rec.Target));
            end if;
            return Rec.Id;
         end;
      end if;

      declare
         Ref_Path : constant String :=
           Join (Version.Repository.Common_Git_Dir (Repo), Name);
      begin
         if Ada.Directories.Exists (Ref_Path)
           and then
             Ada.Directories.Kind (Ref_Path) = Ada.Directories.Ordinary_File
         then
            declare
               Id_Text : constant String :=
                 Ada.Strings.Fixed.Trim
                   (Version.Transport.Local.Read_First_Line (Ref_Path),
                    Ada.Strings.Both);
            begin
               --  Follow a loose symbolic ref (e.g. refs/remotes/*/HEAD),
               --  just as the reftable branch above resolves Ref_Symref.
               if Id_Text'Length > 5
                 and then Id_Text (Id_Text'First .. Id_Text'First + 4) = "ref: "
               then
                  return Resolve_Ref
                    (Repo,
                     Ada.Strings.Fixed.Trim
                       (Id_Text (Id_Text'First + 5 .. Id_Text'Last),
                        Ada.Strings.Both));
               end if;

               if not Version.Objects.Is_Valid_Hex_Object_Id (Id_Text) then
                  raise Ada.IO_Exceptions.Data_Error
                    with "invalid ref object id: " & Name;
               end if;

               return Version.Objects.To_Object_Id (Id_Text);
            end;
         end if;

      end;

      if Version.Packed_Refs.Find (Repo => Repo, Name => Name, Id => Packed_Id)
      then
         return Packed_Id;
      end if;

      raise Ada.IO_Exceptions.Data_Error with "ref does not exist: " & Name;
   end Resolve_Ref;

   function Ref_Exists
     (Repo : Version.Repository.Repository_Handle; Name : String)
      return Boolean
   is
      Packed_Id : Version.Objects.Object_Id_Storage := Version.Objects.Zero_Object_Id;
   begin
      if not Version.Ref_Names.Is_Valid_Ref_Name (Name) then
         return False;
      end if;

      if Version.Reftable.Is_Reftable (Repo) then
         declare
            Found   : Boolean;
            Ignored : constant Version.Reftable.Ref_Record :=
              Version.Reftable.Find (Repo, Name, Found);
            pragma Unreferenced (Ignored);
         begin
            return Found;
         end;
      end if;

      declare
         Ref_Path : constant String :=
           Join (Version.Repository.Common_Git_Dir (Repo), Name);
      begin
         if Ada.Directories.Exists (Ref_Path)
           and then
             Ada.Directories.Kind (Ref_Path) = Ada.Directories.Ordinary_File
         then
            declare
               Id_Text : constant String :=
                 Ada.Strings.Fixed.Trim
                   (Version.Transport.Local.Read_First_Line (Ref_Path),
                    Ada.Strings.Both);
            begin
               return Version.Objects.Is_Valid_Hex_Object_Id (Id_Text);
            end;
         end if;

         return
           Version.Packed_Refs.Find
             (Repo => Repo, Name => Name, Id => Packed_Id);
      end;
   end Ref_Exists;

   function Current_Commit_Id
     (Repo : Version.Repository.Repository_Handle) return String
   is
      Head : constant Head_Info := Read_Head (Repo);
   begin
      if Head.Kind = Detached_Commit then
         return To_String (Head.Commit_Value);
      end if;

      declare
         Ref_Name : constant String :=
           "refs/heads/" & To_String (Head.Branch_Value);
      begin
         if not Ref_Exists (Repo => Repo, Name => Ref_Name) then
            return "";
         end if;

         return To_String (Resolve_Ref (Repo => Repo, Name => Ref_Name));
      end;
   end Current_Commit_Id;

   function Current_Branch_Name
     (Repo : Version.Repository.Repository_Handle) return String
   is
      Head : constant Head_Info := Read_Head (Repo);
   begin
      return Branch_Name (Head);
   end Current_Branch_Name;
   procedure Append_Branches_In_Directory
     (Base_Dir : String;
      Prefix   : String;
      Result   : in out Branch_Name_Vectors.Vector)
   is
      Search : Ada.Directories.Search_Type;
      E      : Ada.Directories.Directory_Entry_Type;
      Opened : Boolean := False;
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
         Ada.Directories.Get_Next_Entry (Search, E);

         declare
            Name : constant String := Ada.Directories.Simple_Name (E);
            Full : constant String := Ada.Directories.Full_Name (E);
         begin
            if Name /= "." and then Name /= ".." then
               if Ada.Directories.Kind (E) = Ada.Directories.Directory then
                  Append_Branches_In_Directory
                    (Base_Dir => Full,
                     Prefix   =>
                       (if Prefix'Length = 0
                        then Name
                        else Prefix & "/" & Name),
                     Result   => Result);
               elsif Ada.Directories.Kind (E) = Ada.Directories.Ordinary_File
               then
                  declare
                     Branch : constant String :=
                       (if Prefix'Length = 0
                        then Name
                        else Prefix & "/" & Name);
                  begin
                     if Version.Ref_Names.Is_Valid_Branch_Name (Branch) then
                        declare
                           Id_Text : constant String :=
                             Ada.Strings.Fixed.Trim
                               (Version.Transport.Local.Read_First_Line (Full),
                                Ada.Strings.Both);
                        begin
                           if Version.Objects.Is_Valid_Hex_Object_Id (Id_Text) then
                              Result.Append (To_Unbounded_String (Branch));
                           end if;
                        end;
                     end if;
                  end;
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
   end Append_Branches_In_Directory;

   function Branch_Already_Listed
     (Branches : Branch_Name_Vectors.Vector; Name : String) return Boolean is
   begin
      if Branches.Is_Empty then
         return False;
      end if;

      for I in Branches.First_Index .. Branches.Last_Index loop
         if To_String (Branches.Element (I)) = Name then
            return True;
         end if;
      end loop;

      return False;
   end Branch_Already_Listed;

   procedure Append_Packed_Branches
     (Repo   : Version.Repository.Repository_Handle;
      Result : in out Branch_Name_Vectors.Vector)
   is
      Heads_Prefix : constant String := "refs/heads/";
      Refs         : constant Version.Packed_Refs.Packed_Ref_Vectors.Vector :=
        Version.Packed_Refs.Read_All (Repo);
   begin
      if Refs.Is_Empty then
         return;
      end if;

      for I in Refs.First_Index .. Refs.Last_Index loop
         declare
            Ref_Name : constant String := To_String (Refs.Element (I).Name);
         begin
            if Ref_Name'Length >= Heads_Prefix'Length
              and then
                Ref_Name
                  (Ref_Name'First .. Ref_Name'First + Heads_Prefix'Length - 1)
                = Heads_Prefix
            then
               declare
                  Branch : constant String :=
                    Ref_Name
                      (Ref_Name'First + Heads_Prefix'Length .. Ref_Name'Last);
               begin
                  if Version.Ref_Names.Is_Valid_Branch_Name (Branch)
                    and then not Branch_Already_Listed (Result, Branch)
                  then
                     Result.Append (To_Unbounded_String (Branch));
                  end if;
               end;
            end if;
         end;
      end loop;
   end Append_Packed_Branches;

   function List_Branches
     (Repo : Version.Repository.Repository_Handle)
      return Branch_Name_Vectors.Vector
   is
      Result : Branch_Name_Vectors.Vector;
   begin
      if Version.Reftable.Is_Reftable (Repo) then
         for R of Version.Reftable.Live_Refs (Repo) loop
            declare
               Name : constant String := To_String (R.Name);
            begin
               if Name'Length > Heads_Prefix'Length
                 and then Name (Name'First .. Name'First
                                  + Heads_Prefix'Length - 1) = Heads_Prefix
               then
                  declare
                     Branch : constant String :=
                       Name (Name'First + Heads_Prefix'Length .. Name'Last);
                  begin
                     if Version.Ref_Names.Is_Valid_Branch_Name (Branch) then
                        Result.Append (To_Unbounded_String (Branch));
                     end if;
                  end;
               end if;
            end;
         end loop;
         return Result;
      end if;

      Append_Branches_In_Directory
        (Base_Dir =>
           Join (Version.Repository.Common_Git_Dir (Repo), "refs/heads"),
         Prefix   => "",
         Result   => Result);

      Append_Packed_Branches (Repo => Repo, Result => Result);

      return Result;
   end List_Branches;

   function Is_Attached (Head : Head_Info) return Boolean is
   begin
      return Head.Kind = Attached_Branch;
   end Is_Attached;

   function Is_Detached (Head : Head_Info) return Boolean is
   begin
      return Head.Kind = Detached_Commit;
   end Is_Detached;

   function Is_Detached
     (Repo : Version.Repository.Repository_Handle) return Boolean is
   begin
      return Is_Detached (Read_Head (Repo));
   end Is_Detached;

   function Detached_Commit_Id
     (Repo : Version.Repository.Repository_Handle)
      return Version.Objects.Hex_Object_Id
   is
      Head : constant Head_Info := Read_Head (Repo);
   begin
      if Head.Kind /= Detached_Commit then
         raise Ada.IO_Exceptions.Data_Error with "HEAD is not detached";
      end if;

      return Version.Objects.To_Object_Id (To_String (Head.Commit_Value));
   end Detached_Commit_Id;

   function Branch_Name (Head : Head_Info) return String is
   begin
      if Head.Kind /= Attached_Branch then
         raise Ada.IO_Exceptions.Data_Error with "HEAD is detached";
      end if;

      return To_String (Head.Branch_Value);
   end Branch_Name;

   function Commit_Id (Head : Head_Info) return String is
   begin
      if Head.Kind /= Detached_Commit then
         raise Ada.IO_Exceptions.Data_Error
           with "HEAD is attached to a branch, not a direct commit";
      end if;

      return To_String (Head.Commit_Value);
   end Commit_Id;

   procedure Write_Detached_HEAD
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id)
   is
      Head_Path : constant String :=
        Join (Version.Repository.Git_Dir (Repo), "HEAD");
   begin
      if Version.Reftable.Is_Reftable (Repo) then
         Reftable_Put
           (Repo,
            (Name => To_Unbounded_String ("HEAD"),
             Kind => Version.Reftable.Ref_Direct,
             Id   => Commit_Id,
             others => <>));
         return;
      end if;
      Atomic_Write_Ref (Path => Head_Path, Object_Id => Commit_Id);
   end Write_Detached_HEAD;

   procedure Write_Detached_HEAD
     (Repo         : Version.Repository.Repository_Handle;
      Commit_Id    : Version.Objects.Hex_Object_Id;
      Expected_Old : Version.Objects.Hex_Object_Id)
   is
      Head : constant Head_Info := Read_Head (Repo);
   begin
      if Head.Kind /= Detached_Commit
        or else To_String (Head.Commit_Value) /= To_String (Expected_Old)
      then
         raise Ada.IO_Exceptions.Data_Error with "expected old HEAD mismatch";
      end if;

      Write_Detached_HEAD (Repo => Repo, Commit_Id => Commit_Id);
   end Write_Detached_HEAD;

   procedure Write_Symbolic_HEAD
     (Repo   : Version.Repository.Repository_Handle;
      Target : String)
   is
      Path      : constant String :=
        Version.Files.Join (Version.Repository.Git_Dir (Repo), "HEAD");
      Lock_Path : constant String := Path & ".lock";
   begin
      if Version.Reftable.Is_Reftable (Repo) then
         Version.Ref_Names.Require_Ref_Name (Target);
         Reftable_Put
           (Repo,
            (Name   => To_Unbounded_String ("HEAD"),
             Kind   => Version.Reftable.Ref_Symref,
             Target => To_Unbounded_String (Target),
             others => <>));
         return;
      end if;

      Version.Ref_Names.Require_Ref_Name (Target);

      if Ada.Directories.Exists (Lock_Path) then
         raise Ada.IO_Exceptions.Data_Error
           with "lock file already exists: " & Lock_Path;
      end if;

      Version.Files.Write_Binary_File
        (Path    => Lock_Path,
         Content => "ref: " & Target & Character'Val (10));
      Version.Files.Atomic_Replace (Lock_Path, Path);
   end Write_Symbolic_HEAD;

   procedure Atomic_Write_Ref
     (Path : String; Object_Id : Version.Objects.Hex_Object_Id) is
   begin
      Validate_Atomic_Write_Path (Path);

      declare
         Lock_Path : constant String := Path & ".lock";
      begin
         if Ada.Directories.Exists (Lock_Path) then
            raise Ada.IO_Exceptions.Data_Error
              with "lock file already exists: " & Lock_Path;
         end if;

         Ensure_Parent_Directory (Path);

         Version.Files.Write_Binary_File
           (Path    => Lock_Path,
            Content => To_String (Object_Id) & Character'Val (10));

         Version.Files.Atomic_Replace (Lock_Path, Path);
      end;
   end Atomic_Write_Ref;
end Version.Refs;
