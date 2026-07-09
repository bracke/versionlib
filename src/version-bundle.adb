with Ada.IO_Exceptions;

with Version.Files;
with Version.History;
with Version.Pack;
with Version.Pack_Write;

package body Version.Bundle is
   use Version.Objects;

   use Ada.Strings.Unbounded;

   LF : constant Character := Character'Val (10);

   --  Parse the textual header of Content, filling Info and setting
   --  Pack_Start to the index of the first packfile byte (one past the blank
   --  line that terminates the header, or Content'Last + 1 if none).
   procedure Scan_Header
     (Content    : String;
      Bundle_Path : String;
      Info       : out Bundle_Info;
      Pack_Start : out Positive)
   is
      Pos        : Positive := Content'First;
      First_Line : Boolean := True;
   begin
      Info := (others => <>);
      Pack_Start := Content'Last + 1;
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
                  Pack_Start := Pos;
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
   end Scan_Header;

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
      Pack_Start : Positive;
   begin
      Scan_Header (Content, Bundle_Path, Info, Pack_Start);
      return Info;
   end Read_Header;

   procedure Unbundle
     (Repo        : Version.Repository.Repository_Handle;
      Bundle_Path : String;
      Info        : out Bundle_Info)
   is
      Content    : constant String :=
        Version.Files.Read_Binary_File (Bundle_Path);
      Pack_Start : Positive;
      Pack_Dir   : constant String :=
        Version.Files.Join
          (Version.Files.Join
             (Version.Repository.Common_Git_Dir (Repo), "objects"), "pack");
      Pack_Path  : constant String :=
        Version.Files.Join (Pack_Dir, "tmp-version-unbundle.pack");
      Pack_Idx   : constant String :=
        Version.Files.Join (Pack_Dir, "tmp-version-unbundle.idx");

      function Object_Present
        (Id : Version.Objects.Hex_Object_Id) return Boolean
      is
         Ignored : constant Version.Objects.Git_Object :=
           Version.Objects.Read_Object (Repo, Id);
         pragma Unreferenced (Ignored);
      begin
         return True;
      exception
         when others =>
            return False;
      end Object_Present;
   begin
      Scan_Header (Content, Bundle_Path, Info, Pack_Start);

      if Pack_Start > Content'Last then
         raise Ada.IO_Exceptions.Data_Error with
           "bundle has no packfile: " & Bundle_Path;
      end if;

      --  A thin/incremental bundle records prerequisite objects the receiving
      --  repository must already have; refuse if any are missing (git parity).
      for Pre of Info.Prerequisites loop
         if not Object_Present (Pre) then
            raise Ada.IO_Exceptions.Data_Error with
              "bundle requires prerequisite object not in repository: "
              & To_String (Pre);
         end if;
      end loop;

      Version.Files.Create_Parent_Directories (Pack_Path);
      Version.Files.Write_Binary_File
        (Pack_Path, Content (Pack_Start .. Content'Last));
      begin
         Version.Pack.Index_Pack (Repo => Repo, Pack_Path => Pack_Path);
      exception
         when others =>
            Version.Files.Delete_File_If_Exists (Pack_Path);
            Version.Files.Delete_File_If_Exists (Pack_Idx);
            raise;
      end;
   end Unbundle;

end Version.Bundle;
