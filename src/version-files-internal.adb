with Ada.Directories;
with Ada.IO_Exceptions;
with GNAT.OS_Lib;

package body Version.Files.Internal is
   use type Ada.Directories.File_Kind;

   procedure Validate_Atomic_Replace_Paths
     (Native_Source : String;
      Native_Target : String;
      Source_Temp   : String;
      Target        : String)
   is
   begin
      if not Ada.Directories.Exists (Native_Source) then
         raise Ada.IO_Exceptions.Name_Error
           with "atomic replace source does not exist: " & Source_Temp;
      elsif Ada.Directories.Kind (Native_Source)
        /= Ada.Directories.Ordinary_File
      then
         raise Ada.IO_Exceptions.Data_Error
           with
             "atomic replace source is not an ordinary file: " & Source_Temp;
      end if;

      Version.Files.Create_Parent_Directories (Target);

      if Ada.Directories.Exists (Native_Target)
        and then Ada.Directories.Kind (Native_Target)
          /= Ada.Directories.Ordinary_File
      then
         raise Ada.IO_Exceptions.Data_Error
           with "atomic replace target is not an ordinary file: " & Target;
      end if;
   end Validate_Atomic_Replace_Paths;

   procedure Delete_Source_On_Failure (Native_Source : String) is
   begin
      if Ada.Directories.Exists (Native_Source)
        and then Ada.Directories.Kind (Native_Source)
          = Ada.Directories.Ordinary_File
      then
         begin
            Ada.Directories.Delete_File (Native_Source);
         exception
            when others =>
               null;
         end;
      end if;
   end Delete_Source_On_Failure;

   procedure Atomic_Replace_Direct
     (Source_Temp : String;
      Target      : String)
   is
      Native_Source : constant String := Version.Files.To_Native_Path (Source_Temp);
      Native_Target : constant String := Version.Files.To_Native_Path (Target);
   begin
      Validate_Atomic_Replace_Paths
        (Native_Source => Native_Source,
         Native_Target => Native_Target,
         Source_Temp   => Source_Temp,
         Target        => Target);

      declare
         Success : Boolean := False;
      begin
         GNAT.OS_Lib.Rename_File
           (Old_Name => Native_Source,
            New_Name => Native_Target,
            Success  => Success);

         if not Success then
            raise Ada.IO_Exceptions.Use_Error
              with "atomic replace rename failed: "
                & Source_Temp & " -> " & Target;
         end if;
      end;
   exception
      when others =>
         Delete_Source_On_Failure (Native_Source);
         raise;
   end Atomic_Replace_Direct;

end Version.Files.Internal;
