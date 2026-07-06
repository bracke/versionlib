with Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Strings;
with Ada.Strings.Fixed;
with Version.Files.Internal;

package body Version.Files.Rollback is
   function Rollback_Suffix (Attempt : Positive) return String is
      use Ada.Strings;
   begin
      if Attempt = 1 then
         return ".version-rollback";
      else
         return ".version-rollback-"
           & Ada.Strings.Fixed.Trim
               (Natural'Image (Attempt), Left);
      end if;
   end Rollback_Suffix;

   function Rollback_Backup_Path
     (Target  : String;
      Attempt : Positive)
      return String
   is
   begin
      return Target & Rollback_Suffix (Attempt);
   end Rollback_Backup_Path;

   function Atomic_Backup_Path (Native_Target : String) return String is
   begin
      for Attempt in 1 .. 1_000 loop
         declare
            Candidate : constant String :=
              Rollback_Backup_Path (Native_Target, Attempt);
         begin
            if not Ada.Directories.Exists (Candidate) then
               return Candidate;
            end if;
         end;
      end loop;

      raise Ada.IO_Exceptions.Use_Error
        with "could not allocate atomic replace rollback path: "
          & Native_Target;
   end Atomic_Backup_Path;

   procedure Replace_With_Rollback
     (Native_Source : String;
      Native_Target : String;
      Source_Temp   : String;
      Target        : String)
   is
      Backup       : constant String := Atomic_Backup_Path (Native_Target);
      Backup_Ready : Boolean := False;
      Replaced     : Boolean := False;
   begin
      Ada.Directories.Rename (Native_Target, Backup);
      Backup_Ready := True;

      begin
         Ada.Directories.Rename (Native_Source, Native_Target);
         Replaced := True;
      exception
         when others =>
            if Backup_Ready and then not Ada.Directories.Exists (Native_Target) then
               Ada.Directories.Rename (Backup, Native_Target);
               Backup_Ready := False;
            end if;
            raise;
      end;

      if Replaced then
         begin
            Ada.Directories.Delete_File (Backup);
            Backup_Ready := False;
         exception
            when others =>
               null;
         end;
      end if;

   exception
      when others =>
         if Backup_Ready and then not Ada.Directories.Exists (Native_Target) then
            begin
               Ada.Directories.Rename (Backup, Native_Target);
            exception
               when others =>
                  null;
            end;
         end if;

         raise Ada.IO_Exceptions.Use_Error
           with "atomic replace rename failed: "
             & Source_Temp & " -> " & Target;
   end Replace_With_Rollback;

   procedure Atomic_Replace_With_Backup_Rollback
     (Source_Temp : String;
      Target      : String)
   is
      Native_Source : constant String := Version.Files.To_Native_Path (Source_Temp);
      Native_Target : constant String := Version.Files.To_Native_Path (Target);
   begin
      Version.Files.Internal.Validate_Atomic_Replace_Paths
        (Native_Source => Native_Source,
         Native_Target => Native_Target,
         Source_Temp   => Source_Temp,
         Target        => Target);

      if Ada.Directories.Exists (Native_Target) then
         Replace_With_Rollback
           (Native_Source => Native_Source,
            Native_Target => Native_Target,
            Source_Temp   => Source_Temp,
            Target        => Target);
      else
         Ada.Directories.Rename (Native_Source, Native_Target);
      end if;
   exception
      when others =>
         Version.Files.Internal.Delete_Source_On_Failure (Native_Source);
         raise;
   end Atomic_Replace_With_Backup_Rollback;

end Version.Files.Rollback;
