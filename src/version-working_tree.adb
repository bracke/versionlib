with Ada.Directories;       use Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Streams;
with Ada.Streams.Stream_IO; use Ada.Streams.Stream_IO;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Containers.Indefinite_Ordered_Maps;
with GNAT.OS_Lib;
with System;
with Interfaces.C;
with Version.Files;
with Version.Platform;

with Version.Hash;

with Version.Submodules;

package body Version.Working_Tree is

   use Ada.Streams;
   use type Version.Platform.Platform_Kind;

   package Path_Boolean_Maps is new
     Ada.Containers.Indefinite_Ordered_Maps
       (Key_Type     => String,
        Element_Type => Boolean);

   type Tracked_Path_Index is record
      Paths       : Path_Boolean_Maps.Map;
      Gitlinks    : Path_Boolean_Maps.Map;
      Directories : Path_Boolean_Maps.Map;
   end record;

   function Scan_Path_Text (Path : String) return String is
   begin
      if Version.Platform.Current = Version.Platform.Windows_Platform then
         return Version.Files.Normalize_Separators (Path);
      else
         return Path;
      end if;
   end Scan_Path_Text;

   function Native_Scan_Path (Path : String) return String is
   begin
      if Version.Platform.Current = Version.Platform.Windows_Platform then
         return Version.Files.To_Native_Path (Path);
      else
         return Path;
      end if;
   end Native_Scan_Path;

   function Relative_Path (Root : String; Full : String) return String is
      Normal_Root : constant String := Scan_Path_Text (Root);
      Normal_Full : constant String := Scan_Path_Text (Full);
      Root_Last   : Natural := Normal_Root'Last;
   begin
      while Root_Last >= Normal_Root'First
        and then Normal_Root (Root_Last) = '/'
      loop
         if Root_Last = Normal_Root'First then
            exit;
         end if;
         Root_Last := Root_Last - 1;
      end loop;

      if Normal_Full'Length <= Root_Last - Normal_Root'First + 1 then
         return "";
      elsif Normal_Full
              (Normal_Full'First
               .. Normal_Full'First + Root_Last - Normal_Root'First)
        /= Normal_Root (Normal_Root'First .. Root_Last)
      then
         return Normal_Full;
      elsif Normal_Full (Normal_Full'First + Root_Last - Normal_Root'First + 1)
        = '/'
      then
         return
           Normal_Full
             (Normal_Full'First
              + Root_Last
              - Normal_Root'First
              + 2
              .. Normal_Full'Last);
      else
         return
           Normal_Full
             (Normal_Full'First
              + Root_Last
              - Normal_Root'First
              + 1
              .. Normal_Full'Last);
      end if;
   end Relative_Path;

   function Read_File_As_String (Path : String) return String is
      File : Stream_IO.File_Type;
   begin
      Stream_IO.Open
        (File, Stream_IO.In_File, Native_Scan_Path (Path));

      declare
         Size : constant Stream_IO.Count := Stream_IO.Size (File);
      begin
         if Size = 0 then
            Stream_IO.Close (File);
            return "";
         end if;

         declare
            Data   : Stream_Element_Array (1 .. Stream_Element_Offset (Size));
            Last   : Stream_Element_Offset;
            Result : String (1 .. Integer (Size));
         begin
            Stream_IO.Read (File, Data, Last);
            Stream_IO.Close (File);

            if Last /= Data'Last then
               raise Ada.IO_Exceptions.Data_Error
                 with "working tree file changed while reading: " & Path;
            end if;

            for I in Data'Range loop
               Result (Integer (I)) := Character'Val (Data (I));
            end loop;

            return Result;
         end;
      end;

   exception
      when others =>
         if Stream_IO.Is_Open (File) then
            Stream_IO.Close (File);
         end if;

         raise;
   end Read_File_As_String;

   function Blob_Id_For_Content
     (Content   : String;
      Algorithm : Version.Hash.Hash_Algorithm)
      return Version.Objects.Hex_Object_Id is
     (Version.Objects.Compute_Object_Id (Algorithm, "blob", Content));

   function Git_Blob_Id
     (Full_Path : String;
      Algorithm : Version.Hash.Hash_Algorithm)
      return Version.Objects.Hex_Object_Id is
     (Blob_Id_For_Content (Read_File_As_String (Full_Path), Algorithm));

   function Readlink
     (Path   : System.Address;
      Buf    : System.Address;
      Bufsiz : Interfaces.C.size_t) return Integer;
   pragma Import (C, Readlink, "__gnat_readlink");

   --  A symlink's git blob content is the link target text (not the bytes of
   --  the file it points to).  Ada.Directories.Kind follows links, so the
   --  scanner must detect and hash symlinks explicitly to match git status.
   function Symlink_Blob_Id
     (Full_Path : String;
      Algorithm : Version.Hash.Hash_Algorithm)
      return Version.Objects.Hex_Object_Id
   is
      Native_Path : constant String := Version.Files.To_Native_Path (Full_Path);
      C_Path      : aliased String := Native_Path & Character'Val (0);
      Buffer      : aliased String (1 .. 8192);
      Count       : constant Integer :=
        Readlink
          (Path   => C_Path (C_Path'First)'Address,
           Buf    => Buffer (Buffer'First)'Address,
           Bufsiz => Interfaces.C.size_t (Buffer'Length));
   begin
      if Count <= 0 or else Count >= Buffer'Length then
         raise Ada.IO_Exceptions.Data_Error with
           "could not read symbolic link target: " & Full_Path;
      end if;
      return Blob_Id_For_Content
        (Buffer (Buffer'First .. Buffer'First + Count - 1), Algorithm);
   end Symlink_Blob_Id;

   procedure Add_Tracked_Directories
     (Index : in out Tracked_Path_Index; Path : String)
   is
      Slash : Natural := 0;
   begin
      for I in Path'Range loop
         if Path (I) = '/' then
            Slash := I;
            if Slash > Path'First then
               Index.Directories.Include
                 (Path (Path'First .. Slash - 1), True);
            end if;
         end if;
      end loop;
   end Add_Tracked_Directories;

   function Build_Tracked_Path_Index
     (Tracked_Paths : Version.Staging.Index_Entry_Vectors.Vector)
      return Tracked_Path_Index
   is
      Result : Tracked_Path_Index;
   begin
      if not Tracked_Paths.Is_Empty then
         for I in Tracked_Paths.First_Index .. Tracked_Paths.Last_Index loop
            declare
               Path : constant String :=
                 To_String (Tracked_Paths.Element (I).Path);
            begin
               Result.Paths.Include (Path, True);
               Add_Tracked_Directories (Result, Path);

               if To_String (Tracked_Paths.Element (I).Mode) = "160000" then
                  Result.Gitlinks.Include (Path, True);
               end if;
            end;
         end loop;
      end if;

      return Result;
   end Build_Tracked_Path_Index;

   function Is_Tracked_Path
     (Index : Tracked_Path_Index; Path : String) return Boolean is
   begin
      return Index.Paths.Contains (Path);
   end Is_Tracked_Path;

   function Is_Tracked_Gitlink
     (Index : Tracked_Path_Index; Path : String) return Boolean is
   begin
      return Index.Gitlinks.Contains (Path);
   end Is_Tracked_Gitlink;

   function Has_Tracked_Path_Under
     (Index : Tracked_Path_Index; Dir_Path : String) return Boolean is
   begin
      return Index.Directories.Contains (Dir_Path);
   end Has_Tracked_Path_Under;

   procedure Scan_Directory
     (Root          : String;
      Dir           : String;
      Ignore_Rules  : Version.Ignore.Ignore_Rules;
      Tracked_Index : Tracked_Path_Index;
      Use_Ignore    : Boolean;
      Use_Pathspec  : Boolean;
      Pathspecs     : Version.Pathspec.Pathspec_Vectors.Vector;
      Algorithm     : Version.Hash.Hash_Algorithm;
      Result        : in out Working_File_Vectors.Vector)
   is
      Search : Ada.Directories.Search_Type;
      E      : Ada.Directories.Directory_Entry_Type;
      Opened : Boolean := False;
   begin
      Ada.Directories.Start_Search
        (Search    => Search,
         Directory => Dir,
         Pattern   => "",
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
               if GNAT.OS_Lib.Is_Symbolic_Link (Full) then
                  declare
                     Rel_File : constant String :=
                       Relative_Path (Root => Root, Full => Full);
                     Ignored  : constant Boolean :=
                       Use_Ignore
                       and then
                         Version.Ignore.Is_Ignored
                           (Rules         => Ignore_Rules,
                            Relative_Path => Rel_File,
                            Is_Directory  => False);
                  begin
                     if ((not Ignored)
                         or else Is_Tracked_Path (Tracked_Index, Rel_File))
                       and then
                         ((not Use_Pathspec)
                          or else
                            Version.Pathspec.Matches_Any
                              (Pathspecs, Rel_File, Is_Directory => False))
                     then
                        Result.Append
                          (Version.Working_Tree.Working_File'
                             (Path => To_Unbounded_String (Rel_File),
                              Id   => Symlink_Blob_Id (Full, Algorithm)));
                     end if;
                  end;
               elsif Ada.Directories.Kind (E) = Ada.Directories.Directory then
                  if Name /= ".git" then
                     declare
                        Rel_Dir : constant String :=
                          Relative_Path (Root => Root, Full => Full);
                        Ignored : constant Boolean :=
                          Use_Ignore
                          and then
                            Version.Ignore.Is_Ignored
                              (Rules         => Ignore_Rules,
                               Relative_Path => Rel_Dir,
                               Is_Directory  => True);
                     begin
                        if Is_Tracked_Gitlink (Tracked_Index, Rel_Dir) then
                           if (not Use_Pathspec)
                             or else
                               Version.Pathspec.Matches_Any
                                 (Pathspecs, Rel_Dir, Is_Directory => True)
                           then
                              declare
                                 Repo :
                                   constant Version
                                              .Repository
                                              .Repository_Handle :=
                                     Version.Repository.Open;
                                 Head : constant String :=
                                   Version.Submodules.Submodule_Head
                                     (Repo, Rel_Dir);
                              begin
                                 if Version.Objects.Is_Valid_Hex_Object_Id
                                      (Head)
                                 then
                                    Result.Append
                                      (Version.Working_Tree.Working_File'
                                         (Path =>
                                            To_Unbounded_String (Rel_Dir),
                                          Id   =>
                                            Version.Objects.To_Object_Id
                                              (Head)));
                                 end if;
                              end;
                           end if;
                        elsif (not Ignored)
                          or else
                            Has_Tracked_Path_Under (Tracked_Index, Rel_Dir)
                        then
                           Scan_Directory
                             (Root          => Root,
                              Dir           => Full,
                              Ignore_Rules  => Ignore_Rules,
                              Tracked_Index => Tracked_Index,
                              Use_Ignore    => Use_Ignore,
                              Use_Pathspec  => Use_Pathspec,
                              Pathspecs     => Pathspecs,
                              Algorithm     => Algorithm,
                              Result        => Result);
                        end if;
                     end;
                  end if;
               elsif Ada.Directories.Kind (E) = Ada.Directories.Ordinary_File
               then
                  declare
                     Rel_File : constant String :=
                       Relative_Path (Root => Root, Full => Full);
                     Ignored  : constant Boolean :=
                       Use_Ignore
                       and then
                         Version.Ignore.Is_Ignored
                           (Rules         => Ignore_Rules,
                            Relative_Path => Rel_File,
                            Is_Directory  => False);
                  begin
                     if ((not Ignored)
                         or else Is_Tracked_Path (Tracked_Index, Rel_File))
                       and then
                         ((not Use_Pathspec)
                          or else
                            Version.Pathspec.Matches_Any
                              (Pathspecs, Rel_File, Is_Directory => False))
                     then
                        Result.Append
                          (Version.Working_Tree.Working_File'
                             (Path => To_Unbounded_String (Rel_File),
                              Id   => Git_Blob_Id (Full, Algorithm)));
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
   end Scan_Directory;

   function Scan
     (Repo : Version.Repository.Repository_Handle)
      return Working_File_Vectors.Vector
   is
      Result : Working_File_Vectors.Vector;
   begin
      declare
         Empty_Rules     : constant Version.Ignore.Ignore_Rules :=
           Version.Ignore.Load (Repo);
         Empty_Index     : Version.Staging.Index_Entry_Vectors.Vector;
         Empty_Tracked   : constant Tracked_Path_Index :=
           Build_Tracked_Path_Index (Empty_Index);
         Empty_Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector;
      begin
         Scan_Directory
           (Root          => Version.Repository.Root_Path (Repo),
            Dir           => Version.Repository.Root_Path (Repo),
            Ignore_Rules  => Empty_Rules,
            Tracked_Index => Empty_Tracked,
            Use_Ignore    => False,
            Use_Pathspec  => False,
            Pathspecs     => Empty_Pathspecs,
            Algorithm     => Version.Repository.Algorithm (Repo),
            Result        => Result);
      end;

      return Result;
   end Scan;

   function Scan
     (Repo          : Version.Repository.Repository_Handle;
      Ignore_Rules  : Version.Ignore.Ignore_Rules;
      Tracked_Paths : Version.Staging.Index_Entry_Vectors.Vector)
      return Working_File_Vectors.Vector
   is
      Result          : Working_File_Vectors.Vector;
      Tracked_Index   : constant Tracked_Path_Index :=
        Build_Tracked_Path_Index (Tracked_Paths);
      Empty_Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector;
   begin
      Scan_Directory
        (Root          => Version.Repository.Root_Path (Repo),
         Dir           => Version.Repository.Root_Path (Repo),
         Ignore_Rules  => Ignore_Rules,
         Tracked_Index => Tracked_Index,
         Use_Ignore    => True,
         Use_Pathspec  => False,
         Pathspecs     => Empty_Pathspecs,
         Algorithm     => Version.Repository.Algorithm (Repo),
         Result        => Result);

      return Result;
   end Scan;

   function Scan
     (Repo          : Version.Repository.Repository_Handle;
      Ignore_Rules  : Version.Ignore.Ignore_Rules;
      Tracked_Paths : Version.Staging.Index_Entry_Vectors.Vector;
      Pathspecs     : Version.Pathspec.Pathspec_Vectors.Vector)
      return Working_File_Vectors.Vector
   is
      Result        : Working_File_Vectors.Vector;
      Tracked_Index : constant Tracked_Path_Index :=
        Build_Tracked_Path_Index (Tracked_Paths);
   begin
      if Pathspecs.Is_Empty then
         return
           Scan
             (Repo          => Repo,
              Ignore_Rules  => Ignore_Rules,
              Tracked_Paths => Tracked_Paths);
      end if;

      Scan_Directory
        (Root          => Version.Repository.Root_Path (Repo),
         Dir           => Version.Repository.Root_Path (Repo),
         Ignore_Rules  => Ignore_Rules,
         Tracked_Index => Tracked_Index,
         Use_Ignore    => True,
         Use_Pathspec  => True,
         Pathspecs     => Pathspecs,
         Algorithm     => Version.Repository.Algorithm (Repo),
         Result        => Result);

      return Result;
   end Scan;

end Version.Working_Tree;
