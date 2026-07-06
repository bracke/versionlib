with Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Strings.Unbounded;

with Version.Files;
with Version.Path_Safety;
with Version.Staging;

package body Version.Move is

   use Ada.Strings.Unbounded;

   procedure Move_Path
     (Repo        : Version.Repository.Repository_Handle;
      Source      : String;
      Destination : String;
      Force       : Boolean := False)
   is
      Src_Norm : constant String :=
        Version.Path_Safety.Normalize_Relative_Path (Source);
      Dst_Norm : constant String :=
        Version.Path_Safety.Normalize_Relative_Path (Destination);

      Root     : constant String := Version.Repository.Root_Path (Repo);
      Src_Full : constant String := Version.Files.Join (Root, Src_Norm);
      Dst_Full : constant String := Version.Files.Join (Root, Dst_Norm);

      Entries  : Version.Staging.Index_Entry_Vectors.Vector :=
        Version.Staging.Load (Repo);

      Found     : Boolean := False;
      Src_Entry : Version.Staging.Index_Entry;
   begin
      Version.Path_Safety.Require_Safe_Relative_Path (Src_Norm, "move source");
      Version.Path_Safety.Require_Safe_Relative_Path
        (Dst_Norm, "move destination");

      if Src_Norm = Dst_Norm then
         raise Ada.IO_Exceptions.Data_Error with
           "source and destination are the same: " & Src_Norm;
      end if;

      --  Source must be tracked.
      for I in Entries.First_Index .. Entries.Last_Index loop
         if To_String (Entries.Element (I).Path) = Src_Norm then
            Src_Entry := Entries.Element (I);
            Found := True;
            exit;
         end if;
      end loop;

      if not Found then
         raise Ada.IO_Exceptions.Data_Error with
           "not under version control: " & Src_Norm;
      end if;

      --  Destination must not already be tracked unless forced.
      if not Force
        and then Version.Staging.Find_Path (Entries, Dst_Norm) /= Natural'Last
      then
         raise Ada.IO_Exceptions.Data_Error with
           "destination exists: " & Dst_Norm;
      end if;

      if not Ada.Directories.Exists (Version.Files.To_Native_Path (Src_Full))
      then
         raise Ada.IO_Exceptions.Data_Error with
           "source does not exist in the working tree: " & Src_Norm;
      end if;

      if Ada.Directories.Exists (Version.Files.To_Native_Path (Dst_Full)) then
         if Force then
            Version.Files.Delete_File_If_Exists (Dst_Full);
         else
            raise Ada.IO_Exceptions.Data_Error with
              "destination exists: " & Dst_Norm;
         end if;
      end if;

      --  Move the working-tree file (Rename preserves the executable bit).
      Version.Files.Create_Parent_Directories (Dst_Full);
      Ada.Directories.Rename
        (Old_Name => Version.Files.To_Native_Path (Src_Full),
         New_Name => Version.Files.To_Native_Path (Dst_Full));

      --  Restage: drop the source entry, add the destination with the same
      --  blob and mode.
      Version.Staging.Remove_Path (Entries, Src_Norm);
      Version.Staging.Replace_Entry
        (Entries,
         (Path  => To_Unbounded_String (Dst_Norm),
          Id    => Src_Entry.Id,
          Mode  => Src_Entry.Mode,
          Stage => 0));
      Version.Staging.Sort_By_Path (Entries);
      Version.Staging.Write (Repo, Entries);
   end Move_Path;

   procedure Move_Path
     (Source      : String;
      Destination : String;
      Force       : Boolean := False)
   is
   begin
      Move_Path
        (Repo        => Version.Repository.Open,
         Source      => Source,
         Destination => Destination,
         Force       => Force);
   end Move_Path;

end Version.Move;
