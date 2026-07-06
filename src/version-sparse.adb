with Ada.Directories; use Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;

with Version.Config;
with Version.Files;
with Version.Path_Safety;

package body Version.Sparse is

   function Sparse_Path
     (Repo : Version.Repository.Repository_Handle) return String is
   begin
      return
        Version.Files.Join
          (Version.Repository.Git_Dir (Repo), "info/sparse-checkout");
   end Sparse_Path;

   function Trim_CR (Text : String) return String is
   begin
      if Text'Length > 0 and then Text (Text'Last) = Character'Val (13) then
         return Text (Text'First .. Text'Last - 1);
      else
         return Text;
      end if;
   end Trim_CR;

   function Lower_ASCII (Text : String) return String is
      Result : String := Text;
   begin
      for I in Result'Range loop
         if Result (I) in 'A' .. 'Z' then
            Result (I) :=
              Character'Val
                (Character'Pos (Result (I))
                 - Character'Pos ('A')
                 + Character'Pos ('a'));
         end if;
      end loop;

      return Result;
   end Lower_ASCII;

   function Strip_Config_Comment_And_Quotes (Text : String) return String is
      Value_Last : Natural := Text'Last;
   begin
      if Text'Length = 0 then
         return "";
      end if;

      for I in Text'Range loop
         if Text (I) = '#' or else Text (I) = ';' then
            Value_Last := I - 1;
            exit;
         end if;
      end loop;

      declare
         Trimmed : constant String :=
           Version.Config.Trim
             ((if Value_Last < Text'First
               then ""
               else Text (Text'First .. Value_Last)));
      begin
         if Trimmed'Length >= 2
           and then Trimmed (Trimmed'First) = '"'
           and then Trimmed (Trimmed'Last) = '"'
         then
            return
              Version.Config.Trim
                (Trimmed (Trimmed'First + 1 .. Trimmed'Last - 1));
         else
            return Trimmed;
         end if;
      end;
   end Strip_Config_Comment_And_Quotes;

   function Has_Positive_Pattern
     (Items : String_Vectors.Vector) return Boolean;

   function Contains_Text
     (Items : String_Vectors.Vector; Text : String) return Boolean is
   begin
      if Items.Is_Empty then
         return False;
      end if;

      for I in Items.First_Index .. Items.Last_Index loop
         if Items.Element (I) = Text then
            return True;
         end if;
      end loop;

      return False;
   end Contains_Text;

   function Unique_Pattern_Texts
     (Items : String_Vectors.Vector) return String_Vectors.Vector
   is
      Result : String_Vectors.Vector;
   begin
      if Items.Is_Empty then
         return Result;
      end if;

      for I in Items.First_Index .. Items.Last_Index loop
         declare
            Text : constant String := Version.Config.Trim (Items.Element (I));
         begin
            if Text'Length > 0 and then not Contains_Text (Result, Text) then
               Result.Append (Text);
            end if;
         end;
      end loop;

      return Result;
   end Unique_Pattern_Texts;

   function Core_Sparse_Checkout_Config
     (Repo : Version.Repository.Repository_Handle) return String
   is
      Entries : constant Version.Config.Config_Entry_Vectors.Vector :=
        Version.Config.Read_All (Repo);
   begin
      if not Entries.Is_Empty then
         for I in reverse Entries.First_Index .. Entries.Last_Index loop
            declare
               Item : constant Version.Config.Config_Entry :=
                 Entries.Element (I);
            begin
               if Lower_ASCII (To_String (Item.Section)) = "core"
                 and then Lower_ASCII (To_String (Item.Key)) = "sparsecheckout"
               then
                  return
                    Lower_ASCII
                      (Strip_Config_Comment_And_Quotes
                         (To_String (Item.Value)));
               end if;
            end;
         end loop;
      end if;

      return "";
   end Core_Sparse_Checkout_Config;

   function Enabled
     (Repo : Version.Repository.Repository_Handle) return Boolean
   is
      Path         : constant String := Sparse_Path (Repo);
      Config_Value : constant String := Core_Sparse_Checkout_Config (Repo);
   begin
      if Config_Value = "false"
        or else Config_Value = "no"
        or else Config_Value = "off"
        or else Config_Value = "0"
      then
         return False;
      end if;

      if not Ada.Directories.Exists (Path)
        or else Ada.Directories.Kind (Path) /= Ada.Directories.Ordinary_File
      then
         return False;
      end if;

      return Has_Positive_Pattern (Pattern_Texts (Repo));
   end Enabled;

   function Pattern_Texts
     (Repo : Version.Repository.Repository_Handle) return String_Vectors.Vector
   is
      Path   : constant String := Sparse_Path (Repo);
      File   : Ada.Text_IO.File_Type;
      Result : String_Vectors.Vector;
   begin
      if not Ada.Directories.Exists (Path)
        or else Ada.Directories.Kind (Path) /= Ada.Directories.Ordinary_File
      then
         return Result;
      end if;

      Ada.Text_IO.Open
        (File, Ada.Text_IO.In_File, Version.Files.To_Native_Path (Path));

      while not Ada.Text_IO.End_Of_File (File) loop
         declare
            Line : constant String :=
              Version.Config.Trim (Trim_CR (Ada.Text_IO.Get_Line (File)));
         begin
            if Line'Length > 0 and then Line (Line'First) /= '#' then
               Result.Append (Line);
            end if;
         end;
      end loop;

      Ada.Text_IO.Close (File);
      return Result;

   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         raise;
   end Pattern_Texts;

   function Status_Text
     (Repo : Version.Repository.Repository_Handle) return String is
   begin
      if Enabled (Repo) then
         return "enabled" & Character'Val (10);
      else
         return "disabled" & Character'Val (10);
      end if;
   end Status_Text;

   function Patterns
     (Repo : Version.Repository.Repository_Handle)
      return Version.Pathspec.Pathspec_Vectors.Vector
   is
      Texts  : constant String_Vectors.Vector := Pattern_Texts (Repo);
      Result : Version.Pathspec.Pathspec_Vectors.Vector;
   begin
      if not Texts.Is_Empty then
         for I in Texts.First_Index .. Texts.Last_Index loop
            Version.Pathspec.Append_Parse (Result, Texts.Element (I));
         end loop;
      end if;

      return Result;
   end Patterns;

   function Has_Positive_Pattern (Items : String_Vectors.Vector) return Boolean
   is
   begin
      if Items.Is_Empty then
         return False;
      end if;

      for I in Items.First_Index .. Items.Last_Index loop
         declare
            Text   : constant String := Items.Element (I);
            Parsed : constant Version.Pathspec.Pathspec_Item :=
              Version.Pathspec.Parse (Text);
         begin
            if not Version.Pathspec.Is_Excluded (Parsed) then
               return True;
            end if;
         end;
      end loop;

      return False;
   end Has_Positive_Pattern;

   procedure Require_Usable_Pattern_Set (Items : String_Vectors.Vector) is
   begin
      if Items.Is_Empty then
         raise Ada.IO_Exceptions.Data_Error
           with "sparse set requires at least one pathspec";
      end if;

      if not Has_Positive_Pattern (Items) then
         raise Ada.IO_Exceptions.Data_Error
           with "sparse set requires at least one non-exclusion pathspec";
      end if;
   end Require_Usable_Pattern_Set;

   procedure Write_Core_Sparse_Config
     (Repo : Version.Repository.Repository_Handle; Enabled : Boolean)
   is
      Existing : constant Version.Config.Config_Entry_Vectors.Vector :=
        Version.Config.Read_All (Repo);
      Core     : Version.Config.Config_Entry_Vectors.Vector;
      Found    : Boolean := False;
   begin
      if not Existing.Is_Empty then
         for I in Existing.First_Index .. Existing.Last_Index loop
            declare
               Item    : constant Version.Config.Config_Entry :=
                 Existing.Element (I);
               Section : constant String := To_String (Item.Section);
               Key     : constant String := To_String (Item.Key);
            begin
               if Lower_ASCII (Section) = "core" then
                  if Lower_ASCII (Key) = "sparsecheckout" then
                     if not Found then
                        Found := True;
                        Core.Append
                          (Version.Config.Config_Entry'
                             (Section => To_Unbounded_String ("core"),
                              Key     =>
                                To_Unbounded_String ("sparseCheckout"),
                              Value   =>
                                To_Unbounded_String
                                  ((if Enabled then "true" else "false"))));
                     end if;
                  else
                     Core.Append (Item);
                  end if;
               end if;
            end;
         end loop;
      end if;

      if not Found then
         Core.Append
           (Version.Config.Config_Entry'
              (Section => To_Unbounded_String ("core"),
               Key     => To_Unbounded_String ("sparseCheckout"),
               Value   =>
                 To_Unbounded_String ((if Enabled then "true" else "false"))));
      end if;

      Version.Config.Replace_Section
        (Repo => Repo, Section => "core", Entries => Core);
   end Write_Core_Sparse_Config;

   procedure Set_From_Strings
     (Repo  : Version.Repository.Repository_Handle;
      Items : String_Vectors.Vector)
   is
      Path      : constant String := Sparse_Path (Repo);
      Temp_Path : constant String := Path & ".tmp";
      File      : Ada.Text_IO.File_Type;
      Unique    : constant String_Vectors.Vector :=
        Unique_Pattern_Texts (Items);
   begin
      Require_Usable_Pattern_Set (Unique);

      Version.Files.Create_Parent_Directories (Temp_Path);
      Ada.Text_IO.Create
        (File, Ada.Text_IO.Out_File, Version.Files.To_Native_Path (Temp_Path));

      for I in Unique.First_Index .. Unique.Last_Index loop
         Ada.Text_IO.Put_Line (File, Unique.Element (I));
      end loop;

      Ada.Text_IO.Close (File);
      Version.Files.Atomic_Replace (Temp_Path, Path);
      Write_Core_Sparse_Config (Repo, True);

   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         Version.Files.Delete_File_If_Exists (Temp_Path);
         raise;
   end Set_From_Strings;

   procedure Set
     (Repo     : Version.Repository.Repository_Handle;
      Patterns : Version.Pathspec.Pathspec_Vectors.Vector)
   is
      Items : String_Vectors.Vector;
   begin
      if Patterns.Is_Empty then
         raise Ada.IO_Exceptions.Data_Error
           with "sparse set requires at least one pathspec";
      end if;

      for I in Patterns.First_Index .. Patterns.Last_Index loop
         Items.Append (Version.Pathspec.To_Text (Patterns.Element (I)));
      end loop;

      Set_From_Strings (Repo, Items);
   end Set;

   procedure Disable (Repo : Version.Repository.Repository_Handle) is
      Path : constant String := Sparse_Path (Repo);
   begin
      Version.Files.Delete_File_If_Exists (Path);
      Write_Core_Sparse_Config (Repo, False);
   end Disable;

   function Included
     (Repo         : Version.Repository.Repository_Handle;
      Path         : String;
      Is_Directory : Boolean := False) return Boolean is
   begin
      Version.Path_Safety.Require_Safe_Relative_Path (Path, "sparse path");

      if not Enabled (Repo) then
         return True;
      end if;

      return
        Version.Pathspec.Matches_Any
          (Items        => Patterns (Repo),
           Path         => Path,
           Is_Directory => Is_Directory);
   end Included;

end Version.Sparse;
