with Ada.IO_Exceptions;

with Version.Files;
with Version.History;
with Version.Pack_Write;

package body Version.Bundle is
   use Version.Objects;

   use Ada.Strings.Unbounded;

   LF : constant Character := Character'Val (10);

   procedure Create
     (Repo        : Version.Repository.Repository_Handle;
      Bundle_Path : String;
      Refs        : Ref_Vectors.Vector)
   is
      Objects  : Version.Objects.Object_Id_Vectors.Vector;
      Tmp_Pack : constant String := Bundle_Path & ".pack.tmp";
      Tmp_Idx  : constant String := Bundle_Path & ".idx.tmp";
      Header   : Unbounded_String;
   begin
      if Refs.Is_Empty then
         raise Ada.IO_Exceptions.Data_Error with
           "bundle requires at least one ref";
      end if;

      for R of Refs loop
         declare
            Reach : constant Version.Objects.Object_Id_Vectors.Vector :=
              Version.History.Reachable_Objects (Repo, R.Id);
         begin
            for O of Reach loop
               Objects.Append (O);
            end loop;
         end;
      end loop;

      Version.Pack_Write.Write_Pack (Repo, Objects, Tmp_Pack, Tmp_Idx);

      Append (Header, "# v2 git bundle" & LF);
      for R of Refs loop
         Append (Header, To_String (R.Id) & " " & To_String (R.Name) & LF);
      end loop;
      Append (Header, LF);

      declare
         Pack_Bytes : constant String :=
           Version.Files.Read_Binary_File (Tmp_Pack);
      begin
         Version.Files.Write_Binary_File
           (Bundle_Path, To_String (Header) & Pack_Bytes);
      end;

      Version.Files.Delete_File_If_Exists (Tmp_Pack);
      Version.Files.Delete_File_If_Exists (Tmp_Idx);
   exception
      when others =>
         Version.Files.Delete_File_If_Exists (Tmp_Pack);
         Version.Files.Delete_File_If_Exists (Tmp_Idx);
         raise;
   end Create;

   function Read_Header (Bundle_Path : String) return Bundle_Info is
      Content    : constant String :=
        Version.Files.Read_Binary_File (Bundle_Path);
      Info       : Bundle_Info;
      Pos        : Positive := Content'First;
      First_Line : Boolean := True;
   begin
      loop
         declare
            EOL : Natural := 0;
         begin
            for K in Pos .. Content'Last loop
               if Content (K) = LF then
                  EOL := K;
                  exit;
               end if;
            end loop;

            exit when EOL = 0;

            declare
               Line : constant String := Content (Pos .. EOL - 1);
            begin
               Pos := EOL + 1;

               if First_Line then
                  First_Line := False;
                  if Line /= "# v2 git bundle"
                    and then Line /= "# v3 git bundle"
                  then
                     raise Ada.IO_Exceptions.Data_Error with
                       "not a git bundle: " & Bundle_Path;
                  end if;

               elsif Line'Length = 0 then
                  exit;  --  blank line: end of header, packfile follows

               elsif Line (Line'First) = '@' then
                  null;  --  v3 capability line

               elsif Line (Line'First) = '-' then
                  --  Prerequisite: "-<id> [comment]". The id (40/64 hex) runs
                  --  to the first space or end of line.
                  Info.Complete := False;
                  declare
                     Stop : Natural := Line'First + 1;
                  begin
                     while Stop <= Line'Last and then Line (Stop) /= ' ' loop
                        Stop := Stop + 1;
                     end loop;

                     if Stop - 1 >= Line'First + 1
                       and then Is_Valid_Hex_Object_Id
                                  (Line (Line'First + 1 .. Stop - 1))
                     then
                        Info.Prerequisites.Append
                          (To_Object_Id (Line (Line'First + 1 .. Stop - 1)));
                     end if;
                  end;

               else
                  --  Ref line: "<id> <refname>" (id is 40 or 64 hex).
                  declare
                     Space : Natural := 0;
                  begin
                     for I in Line'Range loop
                        if Line (I) = ' ' then
                           Space := I;
                           exit;
                        end if;
                     end loop;

                     if Space /= 0
                       and then Is_Valid_Hex_Object_Id
                                  (Line (Line'First .. Space - 1))
                     then
                        Info.Refs.Append
                          (Ref_Entry'
                             (Id   =>
                                To_Object_Id (Line (Line'First .. Space - 1)),
                              Name => To_Unbounded_String
                                        (Line (Space + 1 .. Line'Last))));
                     end if;
                  end;
               end if;
            end;
         end;
      end loop;

      return Info;
   end Read_Header;

end Version.Bundle;
