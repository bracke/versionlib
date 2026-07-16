with Ada.Directories;
with GNAT.OS_Lib;
with Version.Files;
with Version.Ignore;
with Version.Staging;
with Version.Status;

package body Version.Clean is

   use Ada.Strings.Unbounded;

   package Sorting is new Path_Vectors.Generic_Sorting ("<" => "<");

   function Candidates
     (Repo    : Version.Repository.Repository_Handle;
      Options : Clean_Options)
      return Path_Vectors.Vector
   is
      State   : constant Version.Status.Status_Result :=
        Version.Status.Current_Status_With_Ignored;
      Tracked : constant Version.Staging.Index_Entry_Vectors.Vector :=
        Version.Staging.Load (Repo);
      Result  : Path_Vectors.Vector;

      --  A directory holds tracked content if some index entry lies under it.
      function Dir_Has_Tracked (Dir : String) return Boolean is
      begin
         for E of Tracked loop
            declare
               P : constant String := To_String (E.Path);
            begin
               if P'Length > Dir'Length
                 and then P (P'First .. P'First + Dir'Length - 1) = Dir
                 and then P (P'First + Dir'Length) = '/'
               then
                  return True;
               end if;
            end;
         end loop;
         return False;
      end Dir_Has_Tracked;

      function Already_Listed (Unit : String) return Boolean is
      begin
         for U of Result loop
            if To_String (U) = Unit then
               return True;
            end if;
         end loop;
         return False;
      end Already_Listed;

      --  Collapse a single untracked path to git's removal unit: the shallowest
      --  ancestor directory with no tracked content (reported as "dir/"), or the
      --  file itself when every ancestor directory is tracked.
      procedure Consider (Path : String) is
         Unit   : Unbounded_String := To_Unbounded_String (Path);
         Is_Dir : Boolean := False;
         From   : Natural := Path'First;
      begin
         loop
            declare
               Next : Natural := 0;
            begin
               for K in From .. Path'Last loop
                  if Path (K) = '/' then
                     Next := K;
                     exit;
                  end if;
               end loop;

               exit when Next = 0;

               declare
                  Dir : constant String := Path (Path'First .. Next - 1);
               begin
                  if not Dir_Has_Tracked (Dir) then
                     Unit := To_Unbounded_String (Dir & "/");
                     Is_Dir := True;
                     exit;
                  end if;
                  From := Next + 1;
               end;
            end;
         end loop;

         if Is_Dir and then not Options.Directories then
            return;
         end if;

         if not Already_Listed (To_String (Unit)) then
            Result.Append (Unit);
         end if;
      end Consider;
   begin
      for C of State.Untracked loop
         Consider (To_String (C.Path));
      end loop;

      if Options.Ignored then
         for C of State.Ignored loop
            Consider (To_String (C.Path));
         end loop;
      end if;

      --  git's `-d` also removes untracked directories that hold no untracked
      --  file — the plain-file scan above never sees them (they contribute no
      --  entry to State.Untracked). Walk the worktree for the shallowest such
      --  directories. A directory that does hold an untracked file was already
      --  collapsed to a "dir/" unit by Consider, so it is skipped here.
      if Options.Directories then
         declare
            Root  : constant String := Version.Repository.Root_Path (Repo);
            Rules : constant Version.Ignore.Ignore_Rules :=
              Version.Ignore.Load (Repo);

            --  True if any regular file (or symlink) lies anywhere under Full;
            --  git treats a symlink as a file, never descending through it.
            function Contains_File (Full : String) return Boolean is
               Search : Ada.Directories.Search_Type;
               E      : Ada.Directories.Directory_Entry_Type;
               Found  : Boolean := False;
            begin
               Ada.Directories.Start_Search
                 (Search, Full, "",
                  [Ada.Directories.Ordinary_File => True,
                   Ada.Directories.Directory     => True,
                   Ada.Directories.Special_File  => False]);
               while not Found and then Ada.Directories.More_Entries (Search)
               loop
                  Ada.Directories.Get_Next_Entry (Search, E);
                  declare
                     Name  : constant String := Ada.Directories.Simple_Name (E);
                     Child : constant String := Ada.Directories.Full_Name (E);
                  begin
                     if Name = "." or else Name = ".." then
                        null;
                     elsif GNAT.OS_Lib.Is_Symbolic_Link (Child) then
                        Found := True;
                     elsif Version.Files.Is_Directory (Child) then
                        Found := Contains_File (Child);
                     else
                        Found := True;
                     end if;
                  end;
               end loop;
               Ada.Directories.End_Search (Search);
               return Found;
            end Contains_File;

            procedure Walk (Rel : String) is
               Full   : constant String :=
                 (if Rel = "" then Root
                  else Version.Files.Join (Root, Rel));
               Search : Ada.Directories.Search_Type;
               E      : Ada.Directories.Directory_Entry_Type;
            begin
               Ada.Directories.Start_Search
                 (Search, Full, "",
                  [Ada.Directories.Directory     => True,
                   Ada.Directories.Ordinary_File => False,
                   Ada.Directories.Special_File  => False]);
               while Ada.Directories.More_Entries (Search) loop
                  Ada.Directories.Get_Next_Entry (Search, E);
                  declare
                     Name      : constant String :=
                       Ada.Directories.Simple_Name (E);
                     Child     : constant String :=
                       Ada.Directories.Full_Name (E);
                     Child_Rel : constant String :=
                       (if Rel = "" then Name else Rel & "/" & Name);
                  begin
                     if Name = "." or else Name = ".." or else Name = ".git"
                       or else GNAT.OS_Lib.Is_Symbolic_Link (Child)
                     then
                        null;
                     elsif Dir_Has_Tracked (Child_Rel) then
                        Walk (Child_Rel);
                     elsif Contains_File (Child) then
                        null;  --  Consider already listed this directory
                     elsif Version.Ignore.Is_Ignored
                             (Rules, Child_Rel, Is_Directory => True)
                       and then not Options.Ignored
                     then
                        null;  --  an ignored empty directory needs -x
                     elsif not Already_Listed (Child_Rel & "/") then
                        Result.Append (To_Unbounded_String (Child_Rel & "/"));
                     end if;
                  end;
               end loop;
               Ada.Directories.End_Search (Search);
            end Walk;
         begin
            Walk ("");
         end;
      end if;

      Sorting.Sort (Result);
      return Result;
   end Candidates;

   procedure Remove_Candidate
     (Repo : Version.Repository.Repository_Handle;
      Path : String)
   is
      Root    : constant String := Version.Repository.Root_Path (Repo);
      Is_Dir  : constant Boolean :=
        Path'Length > 0 and then Path (Path'Last) = '/';
      Rel     : constant String :=
        (if Is_Dir then Path (Path'First .. Path'Last - 1) else Path);
   begin
      if Is_Dir then
         Version.Files.Delete_Directory_Tree_If_Exists
           (Version.Files.Join (Root, Rel));
      else
         Version.Files.Remove_File_If_Safe
           (Repo_Root     => Root,
            Relative_Path => Rel);
      end if;
   end Remove_Candidate;

end Version.Clean;
