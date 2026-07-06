with Ada.Containers;
use type Ada.Containers.Count_Type;
with Ada.Containers.Vectors;
with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.IO_Exceptions;
with Ada.Strings.Unbounded;

with Version.Files;
with Version.Ignore;
with Version.Staging;
with Version.Working_Tree;
with Version.Object_Cache;
with Version.Ref_Cache;
with Version.Tree_Cache;

package body Version.Diff is

   use Ada.Strings.Unbounded;
   use Version.Objects;

   type Side_Entry is record
      Path    : Unbounded_String;
      Id      : Version.Objects.Object_Id_Storage := Version.Objects.Zero_Object_Id;
      Present : Boolean := False;
   end record;

   package Side_Entry_Vectors is new
     Ada.Containers.Vectors
       (Index_Type   => Natural,
        Element_Type => Side_Entry);

   package Line_Vectors is new
     Ada.Containers.Vectors
       (Index_Type   => Natural,
        Element_Type => Unbounded_String);

   package Side_Entry_Maps is new
     Ada.Containers.Indefinite_Ordered_Maps
       (Key_Type     => String,
        Element_Type => Side_Entry);

   package Path_Sets is new
     Ada.Containers.Indefinite_Ordered_Maps
       (Key_Type     => String,
        Element_Type => Boolean);

   function Short_Zero return Version.Objects.Hex_Object_Id is
      Z : constant Version.Objects.Object_Id_Storage := Version.Objects.Zero_Object_Id;
   begin
      return Z;
   end Short_Zero;

   function Contains_Nul (Text : String) return Boolean is
   begin
      for C of Text loop
         if C = Character'Val (0) then
            return True;
         end if;
      end loop;

      return False;
   end Contains_Nul;

   function Blob_Content
     (Repo  : Version.Repository.Repository_Handle;
      Cache : in out Version.Object_Cache.Object_Cache;
      Id    : Version.Objects.Hex_Object_Id) return String
   is
      Obj : constant Version.Objects.Git_Object :=
        Version.Object_Cache.Read_Object
          (Repo => Repo, Cache => Cache, Id => Id);
   begin
      if Version.Objects.Kind (Obj) /= Version.Objects.Blob_Object then
         raise Ada.IO_Exceptions.Data_Error with "object is not a blob: " & To_String (Id);
      end if;

      return Version.Objects.Content (Obj);
   end Blob_Content;

   function Working_Content
     (Repo : Version.Repository.Repository_Handle; Path : String) return String
   is
   begin
      return
        Version.Files.Read_Binary_File
          (Version.Files.Join (Version.Repository.Root_Path (Repo), Path));
   end Working_Content;

   function Split_Lines (Text : String) return Line_Vectors.Vector is
      Result : Line_Vectors.Vector;
      Start  : Natural := Text'First;
      Pos    : Natural := Text'First;
   begin
      if Text'Length = 0 then
         return Result;
      end if;

      while Pos <= Text'Last loop
         if Text (Pos) = Character'Val (10) then
            if Pos = Start then
               Result.Append (To_Unbounded_String (""));
            else
               Result.Append (To_Unbounded_String (Text (Start .. Pos - 1)));
            end if;
            Start := Pos + 1;
         end if;
         Pos := Pos + 1;
      end loop;

      if Start <= Text'Last then
         Result.Append (To_Unbounded_String (Text (Start .. Text'Last)));
      end if;

      return Result;
   end Split_Lines;

   function Count_Image (Value : Natural) return String is
      Image : constant String := Natural'Image (Value);
   begin
      return Image (Image'First + 1 .. Image'Last);
   end Count_Image;

   procedure Append_Line (Out_Text : in out Unbounded_String; Line : String) is
   begin
      Append (Out_Text, Line);
      Append (Out_Text, Character'Val (10));
   end Append_Line;

   function Unified_File_Diff
     (Path     : String;
      Old_Text : String;
      New_Text : String;
      Old_Name : String;
      New_Name : String) return String
   is
      Result    : Unbounded_String;
      Old_Lines : constant Line_Vectors.Vector := Split_Lines (Old_Text);
      New_Lines : constant Line_Vectors.Vector := Split_Lines (New_Text);
   begin
      if Old_Text = New_Text then
         return "";
      end if;

      Append_Line (Result, "diff --version a/" & Path & " b/" & Path);
      Append_Line (Result, "--- " & Old_Name);
      Append_Line (Result, "+++ " & New_Name);
      Append_Line
        (Result,
         "@@ -1,"
         & Count_Image (Natural (Old_Lines.Length))
         & " +1,"
         & Count_Image (Natural (New_Lines.Length))
         & " @@");

      if not Old_Lines.Is_Empty then
         for I in Old_Lines.First_Index .. Old_Lines.Last_Index loop
            Append_Line (Result, "-" & To_String (Old_Lines.Element (I)));
         end loop;
      end if;

      if not New_Lines.Is_Empty then
         for I in New_Lines.First_Index .. New_Lines.Last_Index loop
            Append_Line (Result, "+" & To_String (New_Lines.Element (I)));
         end loop;
      end if;

      return To_String (Result);
   end Unified_File_Diff;

   function One_File_Diff
     (Repo        : Version.Repository.Repository_Handle;
      Cache       : in out Version.Object_Cache.Object_Cache;
      Path        : String;
      Old_Present : Boolean;
      Old_Id      : Version.Objects.Hex_Object_Id;
      New_Present : Boolean;
      New_Id      : Version.Objects.Hex_Object_Id;
      New_Working : Boolean) return String is
   begin
      if Old_Present and then New_Present and then Old_Id = New_Id then
         return "";
      end if;

      declare
         Old_Text : constant String :=
           (if Old_Present then Blob_Content (Repo, Cache, Old_Id) else "");
         New_Text : constant String :=
           (if not New_Present
            then ""
            elsif New_Working
            then Working_Content (Repo, Path)
            else Blob_Content (Repo, Cache, New_Id));
      begin
         if Contains_Nul (Old_Text) or else Contains_Nul (New_Text) then
            return
              "diff --version a/"
              & Path
              & " b/"
              & Path
              & Character'Val (10)
              & "Binary files differ"
              & Character'Val (10);
         end if;

         return
           Unified_File_Diff
             (Path     => Path,
              Old_Text => Old_Text,
              New_Text => New_Text,
              Old_Name => (if Old_Present then "a/" & Path else "/dev/null"),
              New_Name => (if New_Present then "b/" & Path else "/dev/null"));
      end;
   end One_File_Diff;

   function To_Map
     (Items : Side_Entry_Vectors.Vector) return Side_Entry_Maps.Map
   is
      Result : Side_Entry_Maps.Map;
   begin
      if not Items.Is_Empty then
         for I in Items.First_Index .. Items.Last_Index loop
            declare
               Path : constant String := To_String (Items.Element (I).Path);
            begin
               Result.Include (Path, Items.Element (I));
            end;
         end loop;
      end if;

      return Result;
   end To_Map;

   function Less_Side_Entry
     (Left : Side_Entry; Right : Side_Entry) return Boolean is
   begin
      return To_String (Left.Path) < To_String (Right.Path);
   end Less_Side_Entry;

   procedure Sort (Items : in out Side_Entry_Vectors.Vector) is
      package Side_Sorting is new
        Side_Entry_Vectors.Generic_Sorting ("<" => Less_Side_Entry);
   begin
      if Items.Length < 2 then
         return;
      end if;

      Side_Sorting.Sort (Items);
   end Sort;

   function Head_Tree
     (Repo    : Version.Repository.Repository_Handle;
      Refs    : in out Version.Ref_Cache.Ref_Cache;
      Objects : in out Version.Object_Cache.Object_Cache;
      Trees   : in out Version.Tree_Cache.Tree_Cache)
      return Version.Objects.Tree_Entry_Vectors.Vector
   is
      Empty  : Version.Objects.Tree_Entry_Vectors.Vector;
      Commit : constant String :=
        Version.Ref_Cache.Current_Commit_Id (Repo => Repo, Cache => Refs);
   begin
      if Commit'Length = 0 then
         return Empty;
      end if;

      declare
         Commit_Obj : constant Version.Objects.Git_Object :=
           Version.Object_Cache.Read_Object
             (Repo  => Repo,
              Cache => Objects,
              Id    => Version.Objects.To_Object_Id (Commit));
      begin
         return
           Version.Tree_Cache.Flatten_Tree
             (Repo    => Repo,
              Cache   => Trees,
              Tree_Id => Version.Objects.Commit_Tree_Id (Commit_Obj));
      end;
   end Head_Tree;

   function Tree_For_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Objects   : in out Version.Object_Cache.Object_Cache;
      Trees     : in out Version.Tree_Cache.Tree_Cache;
      Commit_Id : Version.Objects.Hex_Object_Id)
      return Version.Objects.Tree_Entry_Vectors.Vector
   is
      Commit_Obj : constant Version.Objects.Git_Object :=
        Version.Object_Cache.Read_Object
          (Repo => Repo, Cache => Objects, Id => Commit_Id);
   begin
      return
        Version.Tree_Cache.Flatten_Tree
          (Repo    => Repo,
           Cache   => Trees,
           Tree_Id => Version.Objects.Commit_Tree_Id (Commit_Obj));
   end Tree_For_Commit;

   function From_Index
     (Entries : Version.Staging.Index_Entry_Vectors.Vector)
      return Side_Entry_Vectors.Vector
   is
      Result : Side_Entry_Vectors.Vector;
   begin
      if not Entries.Is_Empty then
         for I in Entries.First_Index .. Entries.Last_Index loop
            if Entries.Element (I).Stage = 0 then
               Result.Append
                 (Side_Entry'
                    (Path    => Entries.Element (I).Path,
                     Id      => Entries.Element (I).Id,
                     Present => True));
            end if;
         end loop;
      end if;
      Sort (Result);
      return Result;
   end From_Index;

   function From_Working
     (Entries : Version.Working_Tree.Working_File_Vectors.Vector)
      return Side_Entry_Vectors.Vector
   is
      Result : Side_Entry_Vectors.Vector;
   begin
      if not Entries.Is_Empty then
         for I in Entries.First_Index .. Entries.Last_Index loop
            Result.Append
              (Side_Entry'
                 (Path    => Entries.Element (I).Path,
                  Id      => Entries.Element (I).Id,
                  Present => True));
         end loop;
      end if;
      Sort (Result);
      return Result;
   end From_Working;

   function From_Tree
     (Entries : Version.Objects.Tree_Entry_Vectors.Vector)
      return Side_Entry_Vectors.Vector
   is
      Result : Side_Entry_Vectors.Vector;
   begin
      if not Entries.Is_Empty then
         for I in Entries.First_Index .. Entries.Last_Index loop
            Result.Append
              (Side_Entry'
                 (Path    => Entries.Element (I).Path,
                  Id      => Entries.Element (I).Id,
                  Present => True));
         end loop;
      end if;
      Sort (Result);
      return Result;
   end From_Tree;

   function From_Working_For_Index
     (Working : Version.Working_Tree.Working_File_Vectors.Vector;
      Index   : Version.Staging.Index_Entry_Vectors.Vector)
      return Side_Entry_Vectors.Vector
   is
      Result      : Side_Entry_Vectors.Vector;
      Working_Map : constant Side_Entry_Maps.Map :=
        To_Map (From_Working (Working));
   begin
      if not Index.Is_Empty then
         for I in Index.First_Index .. Index.Last_Index loop
            declare
               Path   : constant String := To_String (Index.Element (I).Path);
               Cursor : constant Side_Entry_Maps.Cursor :=
                 Working_Map.Find (Path);
            begin
               if Side_Entry_Maps.Has_Element (Cursor) then
                  Result.Append (Side_Entry_Maps.Element (Cursor));
               end if;
            end;
         end loop;
      end if;

      Sort (Result);
      return Result;
   end From_Working_For_Index;

   function Filter_Side
     (Side      : Side_Entry_Vectors.Vector;
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector)
      return Side_Entry_Vectors.Vector
   is
      Result : Side_Entry_Vectors.Vector;
   begin
      if Side.Is_Empty then
         return Result;
      end if;

      for I in Side.First_Index .. Side.Last_Index loop
         declare
            Path : constant String := To_String (Side.Element (I).Path);
         begin
            if Version.Pathspec.Matches_Any (Pathspecs, Path) then
               Result.Append (Side.Element (I));
            end if;
         end;
      end loop;

      return Result;
   end Filter_Side;

   function Diff_Sides
     (Repo        : Version.Repository.Repository_Handle;
      Objects     : in out Version.Object_Cache.Object_Cache;
      Old_Side    : Side_Entry_Vectors.Vector;
      New_Side    : Side_Entry_Vectors.Vector;
      New_Working : Boolean) return String
   is
      Old_Map : constant Side_Entry_Maps.Map := To_Map (Old_Side);
      New_Map : constant Side_Entry_Maps.Map := To_Map (New_Side);
      Paths   : Path_Sets.Map;
      Result  : Unbounded_String;
   begin
      if not Old_Side.Is_Empty then
         for I in Old_Side.First_Index .. Old_Side.Last_Index loop
            Paths.Include (To_String (Old_Side.Element (I).Path), True);
         end loop;
      end if;

      if not New_Side.Is_Empty then
         for I in New_Side.First_Index .. New_Side.Last_Index loop
            Paths.Include (To_String (New_Side.Element (I).Path), True);
         end loop;
      end if;

      declare
         Cursor : Path_Sets.Cursor := Paths.First;
      begin
         while Path_Sets.Has_Element (Cursor) loop
            declare
               Path       : constant String := Path_Sets.Key (Cursor);
               Old_Cursor : constant Side_Entry_Maps.Cursor :=
                 Old_Map.Find (Path);
               New_Cursor : constant Side_Entry_Maps.Cursor :=
                 New_Map.Find (Path);
               Old_E      : constant Side_Entry :=
                 (if not Side_Entry_Maps.Has_Element (Old_Cursor)
                  then
                    Side_Entry'
                      (Path    => To_Unbounded_String (Path),
                       Id      => Short_Zero,
                       Present => False)
                  else Side_Entry_Maps.Element (Old_Cursor));
               New_E      : constant Side_Entry :=
                 (if not Side_Entry_Maps.Has_Element (New_Cursor)
                  then
                    Side_Entry'
                      (Path    => To_Unbounded_String (Path),
                       Id      => Short_Zero,
                       Present => False)
                  else Side_Entry_Maps.Element (New_Cursor));
            begin
               Append
                 (Result,
                  One_File_Diff
                    (Repo        => Repo,
                     Cache       => Objects,
                     Path        => Path,
                     Old_Present => Old_E.Present,
                     Old_Id      => Old_E.Id,
                     New_Present => New_E.Present,
                     New_Id      => New_E.Id,
                     New_Working => New_Working));
            end;

            Path_Sets.Next (Cursor);
         end loop;
      end;

      return To_String (Result);
   end Diff_Sides;

   function Diff_Working_Tree
     (Repo    : Version.Repository.Repository_Handle;
      Options : Diff_Options := (others => <>)) return String
   is
      pragma Unreferenced (Options);
   begin
      declare
         Index   : constant Version.Staging.Index_Entry_Vectors.Vector :=
           Version.Staging.Load (Repo);
         Ignore  : Version.Ignore.Ignore_Rules := Version.Ignore.Load (Repo);
         Working : constant Version.Working_Tree.Working_File_Vectors.Vector :=
           Version.Working_Tree.Scan
             (Repo => Repo, Ignore_Rules => Ignore, Tracked_Paths => Index);
      begin
         declare
            Objects : Version.Object_Cache.Object_Cache;
         begin
            return
              Diff_Sides
                (Repo        => Repo,
                 Objects     => Objects,
                 Old_Side    => From_Index (Index),
                 New_Side    => From_Working_For_Index (Working, Index),
                 New_Working => True);
         end;
      end;
   end Diff_Working_Tree;

   function Diff_Working_Tree
     (Repo      : Version.Repository.Repository_Handle;
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector;
      Options   : Diff_Options := (others => <>)) return String
   is
      pragma Unreferenced (Options);
   begin
      declare
         Index   : constant Version.Staging.Index_Entry_Vectors.Vector :=
           Version.Staging.Load (Repo);
         Ignore  : Version.Ignore.Ignore_Rules := Version.Ignore.Load (Repo);
         Working : constant Version.Working_Tree.Working_File_Vectors.Vector :=
           Version.Working_Tree.Scan
             (Repo          => Repo,
              Ignore_Rules  => Ignore,
              Tracked_Paths => Index,
              Pathspecs     => Pathspecs);
      begin
         declare
            Objects : Version.Object_Cache.Object_Cache;
         begin
            return
              Diff_Sides
                (Repo        => Repo,
                 Objects     => Objects,
                 Old_Side    => Filter_Side (From_Index (Index), Pathspecs),
                 New_Side    =>
                   Filter_Side
                     (From_Working_For_Index (Working, Index), Pathspecs),
                 New_Working => True);
         end;
      end;
   end Diff_Working_Tree;

   function Diff_Staged
     (Repo    : Version.Repository.Repository_Handle;
      Options : Diff_Options := (others => <>)) return String
   is
      pragma Unreferenced (Options);
   begin
      declare
         Objects : Version.Object_Cache.Object_Cache;
         Refs    : Version.Ref_Cache.Ref_Cache;
         Trees   : Version.Tree_Cache.Tree_Cache;
      begin
         return
           Diff_Sides
             (Repo        => Repo,
              Objects     => Objects,
              Old_Side    =>
                From_Tree
                  (Head_Tree
                     (Repo    => Repo,
                      Refs    => Refs,
                      Objects => Objects,
                      Trees   => Trees)),
              New_Side    => From_Index (Version.Staging.Load (Repo)),
              New_Working => False);
      end;
   end Diff_Staged;

   function Diff_Staged
     (Repo      : Version.Repository.Repository_Handle;
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector;
      Options   : Diff_Options := (others => <>)) return String
   is
      pragma Unreferenced (Options);
   begin
      declare
         Objects : Version.Object_Cache.Object_Cache;
         Refs    : Version.Ref_Cache.Ref_Cache;
         Trees   : Version.Tree_Cache.Tree_Cache;
      begin
         return
           Diff_Sides
             (Repo        => Repo,
              Objects     => Objects,
              Old_Side    =>
                Filter_Side
                  (From_Tree
                     (Head_Tree
                        (Repo    => Repo,
                         Refs    => Refs,
                         Objects => Objects,
                         Trees   => Trees)),
                   Pathspecs),
              New_Side    =>
                Filter_Side
                  (From_Index (Version.Staging.Load (Repo)), Pathspecs),
              New_Working => False);
      end;
   end Diff_Staged;

   function Diff_Cached
     (Repo    : Version.Repository.Repository_Handle;
      Options : Diff_Options := (others => <>)) return String is
   begin
      return Diff_Staged (Repo, Options);
   end Diff_Cached;

   function Diff_Cached
     (Repo      : Version.Repository.Repository_Handle;
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector;
      Options   : Diff_Options := (others => <>)) return String is
   begin
      return Diff_Staged (Repo, Pathspecs, Options);
   end Diff_Cached;

   function Diff_Commits
     (Repo    : Version.Repository.Repository_Handle;
      Old_Id  : Version.Objects.Hex_Object_Id;
      New_Id  : Version.Objects.Hex_Object_Id;
      Options : Diff_Options := (others => <>)) return String
   is
      pragma Unreferenced (Options);
   begin
      declare
         Objects : Version.Object_Cache.Object_Cache;
         Trees   : Version.Tree_Cache.Tree_Cache;
      begin
         return
           Diff_Sides
             (Repo        => Repo,
              Objects     => Objects,
              Old_Side    =>
                From_Tree
                  (Tree_For_Commit
                     (Repo      => Repo,
                      Objects   => Objects,
                      Trees     => Trees,
                      Commit_Id => Old_Id)),
              New_Side    =>
                From_Tree
                  (Tree_For_Commit
                     (Repo      => Repo,
                      Objects   => Objects,
                      Trees     => Trees,
                      Commit_Id => New_Id)),
              New_Working => False);
      end;
   end Diff_Commits;

   function Diff_Commits
     (Repo      : Version.Repository.Repository_Handle;
      Old_Id    : Version.Objects.Hex_Object_Id;
      New_Id    : Version.Objects.Hex_Object_Id;
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector;
      Options   : Diff_Options := (others => <>)) return String
   is
      pragma Unreferenced (Options);
   begin
      if Pathspecs.Is_Empty then
         return Diff_Commits (Repo, Old_Id, New_Id);
      end if;

      declare
         Objects : Version.Object_Cache.Object_Cache;
         Trees   : Version.Tree_Cache.Tree_Cache;
      begin
         return
           Diff_Sides
             (Repo        => Repo,
              Objects     => Objects,
              Old_Side    =>
                Filter_Side
                  (From_Tree
                     (Tree_For_Commit
                        (Repo      => Repo,
                         Objects   => Objects,
                         Trees     => Trees,
                         Commit_Id => Old_Id)),
                   Pathspecs),
              New_Side    =>
                Filter_Side
                  (From_Tree
                     (Tree_For_Commit
                        (Repo      => Repo,
                         Objects   => Objects,
                         Trees     => Trees,
                         Commit_Id => New_Id)),
                   Pathspecs),
              New_Working => False);
      end;
   end Diff_Commits;

   function Diff_Root_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Options   : Diff_Options := (others => <>)) return String
   is
      pragma Unreferenced (Options);
      Empty : Side_Entry_Vectors.Vector;
   begin
      declare
         Objects : Version.Object_Cache.Object_Cache;
         Trees   : Version.Tree_Cache.Tree_Cache;
      begin
         return
           Diff_Sides
             (Repo        => Repo,
              Objects     => Objects,
              Old_Side    => Empty,
              New_Side    =>
                From_Tree
                  (Tree_For_Commit
                     (Repo      => Repo,
                      Objects   => Objects,
                      Trees     => Trees,
                      Commit_Id => Commit_Id)),
              New_Working => False);
      end;
   end Diff_Root_Commit;

   function Diff_Root_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector;
      Options   : Diff_Options := (others => <>)) return String
   is
      pragma Unreferenced (Options);
      Empty : Side_Entry_Vectors.Vector;
   begin
      if Pathspecs.Is_Empty then
         return Diff_Root_Commit (Repo, Commit_Id);
      end if;

      declare
         Objects : Version.Object_Cache.Object_Cache;
         Trees   : Version.Tree_Cache.Tree_Cache;
      begin
         return
           Diff_Sides
             (Repo        => Repo,
              Objects     => Objects,
              Old_Side    => Empty,
              New_Side    =>
                Filter_Side
                  (From_Tree
                     (Tree_For_Commit
                        (Repo      => Repo,
                         Objects   => Objects,
                         Trees     => Trees,
                         Commit_Id => Commit_Id)),
                   Pathspecs),
              New_Working => False);
      end;
   end Diff_Root_Commit;

end Version.Diff;
