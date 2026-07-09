with Ada.IO_Exceptions;
with Ada.Text_IO;

with Version.Files;

package body Version.Config is

   function Section_Name (Line : String) return String is
      Text : constant String := Trim (Line);
   begin
      if Text'Length < 2
        or else Text (Text'First) /= '['
        or else Text (Text'Last) /= ']'
      then
         return "";
      end if;

      return Text (Text'First + 1 .. Text'Last - 1);
   end Section_Name;

   function Join (Left, Right : String) return String
   renames Version.Files.Join;

   function Is_Blank (C : Character) return Boolean is
   begin
      return
        C = ' '
        or else C = Character'Val (9)
        or else C = Character'Val (10)
        or else C = Character'Val (13);
   end Is_Blank;

   function Trim (Value : String) return String is
      First : Natural := Value'First;
      Last  : Natural := Value'Last;
   begin
      while First <= Value'Last and then Is_Blank (Value (First)) loop
         First := First + 1;
      end loop;

      while Last >= Value'First and then Is_Blank (Value (Last)) loop
         Last := Last - 1;
      end loop;

      if First > Last then
         return "";
      end if;

      return Value (First .. Last);
   end Trim;

   function Unquote (Value : String) return String is
      V : constant String := Trim (Value);
   begin
      if V'Length >= 2 and then V (V'First) = '"' and then V (V'Last) = '"'
      then
         return V (V'First + 1 .. V'Last - 1);
      end if;

      return V;
   end Unquote;

   --  Decode git-config value escapes (\n \t \b, backslash-escapes, quotes)
   --  and strip unquoted inline comments, matching git's config reader.
   function Decode_Config_Value (Raw : String) return String is
      Result   : String (1 .. Raw'Length);
      Len      : Natural := 0;
      In_Quote : Boolean := False;
      I        : Natural := Raw'First;
   begin
      while I <= Raw'Last loop
         declare
            C : constant Character := Raw (I);
         begin
            if C = '\' and then I < Raw'Last then
               Len := Len + 1;
               case Raw (I + 1) is
                  when 'n' => Result (Len) := Character'Val (10);
                  when 't' => Result (Len) := Character'Val (9);
                  when 'b' => Result (Len) := Character'Val (8);
                  when others => Result (Len) := Raw (I + 1);
               end case;
               I := I + 2;
            elsif C = '"' then
               In_Quote := not In_Quote;
               I := I + 1;
            elsif (not In_Quote) and then (C = '#' or else C = ';') then
               exit;
            else
               Len := Len + 1;
               Result (Len) := C;
               I := I + 1;
            end if;
         end;
      end loop;
      return Trim (Result (1 .. Len));
   end Decode_Config_Value;

   function Lower (Value : String) return String is
      Result : String := Value;
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
   end Lower;

   procedure Read_Config_File
     (Path  : String;
      Name  : in out Unbounded_String;
      Email : in out Unbounded_String)
   is
      File            : Ada.Text_IO.File_Type;
      In_User_Section : Boolean := False;
   begin
      if not Version.Files.Is_Ordinary_File (Path) then
         return;
      end if;

      Ada.Text_IO.Open
        (File, Ada.Text_IO.In_File, Version.Files.To_Native_Path (Path));

      while not Ada.Text_IO.End_Of_File (File) loop
         declare
            Line : constant String := Trim (Ada.Text_IO.Get_Line (File));
         begin
            if Line'Length = 0 then
               null;

            elsif Line (Line'First) = '[' then
               In_User_Section := Section_Name (Line) = "user";

            elsif In_User_Section then
               declare
                  Eq_Pos : Natural := 0;
               begin
                  for I in Line'Range loop
                     if Line (I) = '=' then
                        Eq_Pos := I;
                        exit;
                     end if;
                  end loop;

                  if Eq_Pos /= 0 then
                     declare
                        Key : constant String :=
                          Lower (Trim (Line (Line'First .. Eq_Pos - 1)));

                        Val : constant String :=
                          Unquote (Line (Eq_Pos + 1 .. Line'Last));
                     begin
                        if Key = "name" then
                           Name := To_Unbounded_String (Val);
                        elsif Key = "email" then
                           Email := To_Unbounded_String (Val);
                        end if;
                     end;
                  end if;
               end;
            end if;
         end;
      end loop;

      Ada.Text_IO.Close (File);

   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;

         raise;
   end Read_Config_File;

   function User_Identity
     (Repo : Version.Repository.Repository_Handle) return Identity
   is
      Name  : Unbounded_String;
      Email : Unbounded_String;

      Local_Config : constant String :=
        Join (Version.Repository.Common_Git_Dir (Repo), "config");
   begin
      Read_Config_File (Path => Local_Config, Name => Name, Email => Email);

      if Length (Name) = 0 then
         Name := To_Unbounded_String ("Version");
      end if;

      if Length (Email) = 0 then
         Email := To_Unbounded_String ("version@example.invalid");
      end if;

      return (Name => Name, Email => Email);
   end User_Identity;

   function Config_Path
     (Repo : Version.Repository.Repository_Handle) return String is
   begin
      return
        Version.Files.Join
          (Version.Repository.Common_Git_Dir (Repo), "config");
   end Config_Path;

   function Is_Control (C : Character) return Boolean is
   begin
      return Character'Pos (C) < 32 or else Character'Pos (C) = 127;
   end Is_Control;

   procedure Require_Config_Scalar (Value : String; Context : String) is
   begin
      for C of Value loop
         if C = Character'Val (0)
           or else C = Character'Val (10)
           or else C = Character'Val (13)
           or else (Is_Control (C) and then C /= Character'Val (9))
         then
            raise Ada.IO_Exceptions.Data_Error
              with Context & " contains an unsafe control character";
         end if;
      end loop;
   end Require_Config_Scalar;

   procedure Require_Config_Key
     (Key : String; Context : String := "config key") is
   begin
      if Key'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error
           with Context & " must not be empty";
      end if;

      for C of Key loop
         if C = '='
           or else C = ' '
           or else C = Character'Val (9)
           or else Is_Control (C)
         then
            raise Ada.IO_Exceptions.Data_Error
              with "invalid " & Context & ": " & Key;
         end if;
      end loop;
   end Require_Config_Key;

   procedure Require_Config_Name
     (Name : String; Context : String := "config name")
   is
      Dot_Seen : Boolean := False;
   begin
      if Name'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error
           with Context & " must not be empty";
      end if;

      for C of Name loop
         if C = '.' then
            Dot_Seen := True;
         end if;

         if C = '='
           or else C = ' '
           or else C = Character'Val (9)
           or else Is_Control (C)
         then
            raise Ada.IO_Exceptions.Data_Error
              with "invalid " & Context & ": " & Name;
         end if;
      end loop;

      if not Dot_Seen then
         raise Ada.IO_Exceptions.Data_Error
           with "invalid " & Context & ": " & Name;
      end if;
   end Require_Config_Name;

   procedure Require_Config_Section
     (Section : String; Context : String := "config section") is
   begin
      if Section'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error
           with Context & " must not be empty";
      end if;

      for C of Section loop
         if C = ']' or else Is_Control (C) then
            raise Ada.IO_Exceptions.Data_Error
              with "invalid " & Context & ": " & Section;
         end if;
      end loop;
   end Require_Config_Section;
   procedure Append_Config_File
     (Path   : String;
      Result : in out Config_Entry_Vectors.Vector)
   is
      File : Ada.Text_IO.File_Type;
      Current_Section : Unbounded_String;
   begin
      if not Version.Files.Is_Ordinary_File (Path) then
         return;
      end if;

      Ada.Text_IO.Open
        (File, Ada.Text_IO.In_File, Version.Files.To_Native_Path (Path));

      while not Ada.Text_IO.End_Of_File (File) loop
         declare
            Line : constant String := Ada.Text_IO.Get_Line (File);

            Text : constant String := Trim (Line);
         begin
            if Text'Length = 0 then
               null;

            elsif Text (Text'First) = '[' then
               Current_Section := To_Unbounded_String (Section_Name (Text));

            elsif Length (Current_Section) > 0 then
               declare
                  Eq_Pos : Natural := 0;
               begin
                  for I in Text'Range loop
                     if Text (I) = '=' then
                        Eq_Pos := I;
                        exit;
                     end if;
                  end loop;

                  if Eq_Pos /= 0 then
                     Result.Append
                       (Config_Entry'
                          (Section => Current_Section,
                           Key     =>
                             To_Unbounded_String
                               (Trim (Text (Text'First .. Eq_Pos - 1))),
                           Value   =>
                             To_Unbounded_String
                               (Decode_Config_Value
                                  (Trim (Text (Eq_Pos + 1 .. Text'Last))))));
                  end if;
               end;
            end if;
         end;
      end loop;

      Ada.Text_IO.Close (File);

   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;

         raise;
   end Append_Config_File;

   --  True when extensions.worktreeConfig is set to a true boolean value.
   function Worktree_Config_Enabled
     (Entries : Config_Entry_Vectors.Vector) return Boolean is
   begin
      for E of Entries loop
         if Lower (Config_Entry_Name (E)) = "extensions.worktreeconfig" then
            declare
               V : constant String := Lower (Trim (To_String (E.Value)));
            begin
               return V = "" or else V = "true" or else V = "yes"
                 or else V = "on" or else V = "1";
            end;
         end if;
      end loop;
      return False;
   end Worktree_Config_Enabled;

   function Read_All
     (Repo : Version.Repository.Repository_Handle)
      return Config_Entry_Vectors.Vector
   is
      Result : Config_Entry_Vectors.Vector;
   begin
      Append_Config_File (Config_Path (Repo), Result);

      if Worktree_Config_Enabled (Result) then
         declare
            Worktree_Path : constant String :=
              Version.Files.Join
                (Version.Repository.Git_Dir (Repo), "config.worktree");
            Layered : Config_Entry_Vectors.Vector;
         begin
            --  config.worktree overrides the common config: put its entries
            --  first so first-match lookups resolve to the per-worktree value.
            Append_Config_File (Worktree_Path, Layered);
            for E of Result loop
               Layered.Append (E);
            end loop;
            return Layered;
         end;
      end if;

      return Result;
   end Read_All;

   procedure Write_Entries_To
     (Path    : String;
      Entries : Config_Entry_Vectors.Vector)
   is
      Temp_Path : constant String := Path & ".tmp";

      File : Ada.Text_IO.File_Type;

      Last_Section : Unbounded_String;
   begin
      Version.Files.Create_Parent_Directories (Temp_Path);
      Ada.Text_IO.Create
        (File, Ada.Text_IO.Out_File, Version.Files.To_Native_Path (Temp_Path));

      if not Entries.Is_Empty then
         for I in Entries.First_Index .. Entries.Last_Index loop
            declare
               Item : constant Config_Entry := Entries.Element (I);
            begin
               Require_Config_Section (To_String (Item.Section));
               Require_Config_Key (To_String (Item.Key));
               Require_Config_Scalar (To_String (Item.Value), "config value");

               if To_String (Item.Section) /= To_String (Last_Section) then
                  if Length (Last_Section) > 0 then
                     Ada.Text_IO.New_Line (File);
                  end if;

                  Ada.Text_IO.Put_Line
                    (File, "[" & To_String (Item.Section) & "]");

                  Last_Section := Item.Section;
               end if;

               Ada.Text_IO.Put_Line
                 (File,
                  Character'Val (9)
                  & To_String (Item.Key)
                  & " = "
                  & To_String (Item.Value));
            end;
         end loop;
      end if;

      Ada.Text_IO.Close (File);

      Version.Files.Atomic_Replace (Temp_Path, Path);

   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;

         Version.Files.Delete_File_If_Exists (Temp_Path);

         raise;
   end Write_Entries_To;

   procedure Write_All
     (Repo    : Version.Repository.Repository_Handle;
      Entries : Config_Entry_Vectors.Vector) is
   begin
      Write_Entries_To (Config_Path (Repo), Entries);
   end Write_All;

   function Worktree_Config_Path
     (Repo : Version.Repository.Repository_Handle) return String is
     (Version.Files.Join
        (Version.Repository.Git_Dir (Repo), "config.worktree"));

   function Read_File_Entries (Path : String)
     return Config_Entry_Vectors.Vector
   is
      Result : Config_Entry_Vectors.Vector;
   begin
      Append_Config_File (Path, Result);
      return Result;
   end Read_File_Entries;

   function Worktree_Config_Active
     (Repo : Version.Repository.Repository_Handle) return Boolean is
     (Worktree_Config_Enabled (Read_File_Entries (Config_Path (Repo))));

   procedure Remove_Section
     (Repo : Version.Repository.Repository_Handle; Section : String)
   is
      Existing : constant Config_Entry_Vectors.Vector := Read_All (Repo);

      Result : Config_Entry_Vectors.Vector;

      Found : Boolean := False;
   begin
      Require_Config_Section (Section);

      if not Existing.Is_Empty then
         for I in Existing.First_Index .. Existing.Last_Index loop
            declare
               Item : constant Config_Entry := Existing.Element (I);
            begin
               if Lower (To_String (Item.Section)) = Lower (Section) then
                  Found := True;

               else
                  Result.Append (Item);
               end if;
            end;
         end loop;
      end if;

      if not Found then
         raise Ada.IO_Exceptions.Data_Error
           with "config section does not exist: " & Section;
      end if;

      Write_All (Repo => Repo, Entries => Result);
   end Remove_Section;

   function Config_Entry_Name (Current_Entry : Config_Entry) return String is
      Section     : constant String := To_String (Current_Entry.Section);
      Key         : constant String := To_String (Current_Entry.Key);
      Quote_First : Natural := 0;
      Quote_Last  : Natural := 0;
   begin
      for I in Section'Range loop
         if Section (I) = '"' then
            if Quote_First = 0 then
               Quote_First := I;
            else
               Quote_Last := I;
            end if;
         end if;
      end loop;

      if Quote_First /= 0 and then Quote_Last > Quote_First then
         declare
            Base : constant String :=
              Trim (Section (Section'First .. Quote_First - 1));
            Sub  : constant String :=
              Section (Quote_First + 1 .. Quote_Last - 1);
         begin
            if Base'Length > 0 and then Sub'Length > 0 then
               return Base & "." & Sub & "." & Key;
            end if;
         end;
      end if;

      return Section & "." & Key;
   end Config_Entry_Name;

   function Config_Entry_Line (Current_Entry : Config_Entry) return String is
   begin
      return
        Config_Entry_Name (Current_Entry)
        & "="
        & To_String (Current_Entry.Value);
   end Config_Entry_Line;

   function Last_Dot (Name : String) return Natural is
      Result : Natural := 0;
   begin
      for I in Name'Range loop
         if Name (I) = '.' then
            Result := I;
         end if;
      end loop;

      return Result;
   end Last_Dot;

   procedure Split_Config_Name
     (Name    : String;
      Section : out Unbounded_String;
      Key     : out Unbounded_String)
   is
      First_Dot : Natural := 0;
      Final_Dot : constant Natural := Last_Dot (Name);
   begin
      Require_Config_Name (Name);

      for I in Name'Range loop
         if Name (I) = '.' then
            First_Dot := I;
            exit;
         end if;
      end loop;

      if First_Dot = 0
        or else Final_Dot = 0
        or else Final_Dot = Name'First
        or else Final_Dot = Name'Last
      then
         raise Ada.IO_Exceptions.Data_Error
           with "invalid config name: " & Name;
      end if;

      if First_Dot = Final_Dot then
         Section := To_Unbounded_String (Name (Name'First .. First_Dot - 1));
      else
         Section :=
           To_Unbounded_String
             (Name (Name'First .. First_Dot - 1)
              & " """
              & Name (First_Dot + 1 .. Final_Dot - 1)
              & """");
      end if;

      Key := To_Unbounded_String (Name (Final_Dot + 1 .. Name'Last));

      Require_Config_Section (To_String (Section));
      Require_Config_Key (To_String (Key));
   end Split_Config_Name;

   --  Set/replace Name in the single config file at Path, preserving git's
   --  "append to the last line of the matching section" insertion behavior.
   procedure Set_In_File (Path : String; Name : String; Value : String)
   is
      Items          : constant Config_Entry_Vectors.Vector :=
        Read_File_Entries (Path);
      Result         : Config_Entry_Vectors.Vector;
      Wanted         : constant String := Lower (Name);
      Target_Section : Unbounded_String;
      Target_Key     : Unbounded_String;
      Replaced       : Boolean := False;
      Inserted       : Boolean := False;
   begin
      Require_Config_Name (Name);
      Require_Config_Scalar (Value, "config value");
      Split_Config_Name (Name, Target_Section, Target_Key);

      if not Items.Is_Empty then
         for I in Items.First_Index .. Items.Last_Index loop
            declare
               Item      : constant Config_Entry := Items.Element (I);
               Item_Name : constant String := Lower (Config_Entry_Name (Item));
            begin
               if Item_Name = Wanted then
                  if not Replaced and then not Inserted then
                     Result.Append
                       (Config_Entry'
                          (Section => Item.Section,
                           Key     => Item.Key,
                           Value   => To_Unbounded_String (Value)));
                  end if;

                  Replaced := True;
               else
                  Result.Append (Item);

                  if not Replaced
                    and then not Inserted
                    and then
                      Lower (To_String (Item.Section))
                      = Lower (To_String (Target_Section))
                  then
                     declare
                        Is_Last_In_Section : Boolean := I = Items.Last_Index;
                     begin
                        if not Is_Last_In_Section then
                           declare
                              Next_Item : constant Config_Entry :=
                                Items.Element (I + 1);
                           begin
                              Is_Last_In_Section :=
                                Lower (To_String (Next_Item.Section))
                                /= Lower (To_String (Target_Section));
                           end;
                        end if;

                        if Is_Last_In_Section then
                           Result.Append
                             (Config_Entry'
                                (Section => Target_Section,
                                 Key     => Target_Key,
                                 Value   => To_Unbounded_String (Value)));
                           Inserted := True;
                        end if;
                     end;
                  end if;
               end if;
            end;
         end loop;
      end if;

      if not Replaced and then not Inserted then
         Result.Append
           (Config_Entry'
              (Section => Target_Section,
               Key     => Target_Key,
               Value   => To_Unbounded_String (Value)));
      end if;

      Write_Entries_To (Path, Result);
   end Set_In_File;

   procedure Unset_In_File (Path : String; Name : String)
   is
      Items  : constant Config_Entry_Vectors.Vector := Read_File_Entries (Path);
      Result : Config_Entry_Vectors.Vector;
      Wanted : constant String := Lower (Name);
      Found  : Boolean := False;
   begin
      Require_Config_Name (Name);

      if not Items.Is_Empty then
         for I in Items.First_Index .. Items.Last_Index loop
            declare
               Item      : constant Config_Entry := Items.Element (I);
               Item_Name : constant String := Lower (Config_Entry_Name (Item));
            begin
               if Item_Name = Wanted then
                  Found := True;
               else
                  Result.Append (Item);
               end if;
            end;
         end loop;
      end if;

      if not Found then
         raise Ada.IO_Exceptions.Data_Error
           with "config key does not exist: " & Name;
      end if;

      Write_Entries_To (Path, Result);
   end Unset_In_File;

   procedure Set_Key
     (Repo  : Version.Repository.Repository_Handle;
      Name  : String;
      Value : String) is
   begin
      Set_In_File (Config_Path (Repo), Name, Value);
   end Set_Key;

   procedure Set_Key_Worktree
     (Repo  : Version.Repository.Repository_Handle;
      Name  : String;
      Value : String) is
   begin
      Set_In_File
        ((if Worktree_Config_Active (Repo)
          then Worktree_Config_Path (Repo)
          else Config_Path (Repo)),
         Name, Value);
   end Set_Key_Worktree;

   procedure Unset_Key_Worktree
     (Repo : Version.Repository.Repository_Handle;
      Name : String) is
   begin
      Unset_In_File
        ((if Worktree_Config_Active (Repo)
          then Worktree_Config_Path (Repo)
          else Config_Path (Repo)),
         Name);
   end Unset_Key_Worktree;

   function Has_Key
     (Repo : Version.Repository.Repository_Handle; Name : String)
      return Boolean
   is
      Items  : constant Config_Entry_Vectors.Vector := Read_All (Repo);
      Wanted : constant String := Lower (Name);
   begin
      Require_Config_Name (Name);

      if not Items.Is_Empty then
         for I in Items.First_Index .. Items.Last_Index loop
            declare
               Item_Name : constant String :=
                 Lower (Config_Entry_Name (Items.Element (I)));
            begin
               if Item_Name = Wanted then
                  return True;
               end if;
            end;
         end loop;
      end if;

      return False;
   end Has_Key;

   procedure Unset_Key
     (Repo : Version.Repository.Repository_Handle; Name : String) is
   begin
      Unset_In_File (Config_Path (Repo), Name);
   end Unset_Key;

   function Get_Value
     (Repo : Version.Repository.Repository_Handle; Name : String) return String
   is
      Items  : constant Config_Entry_Vectors.Vector := Read_All (Repo);
      Wanted : constant String := Lower (Name);
   begin
      Require_Config_Name (Name);

      if not Items.Is_Empty then
         for I in Items.First_Index .. Items.Last_Index loop
            declare
               Item_Name : constant String :=
                 Lower (Config_Entry_Name (Items.Element (I)));
            begin
               if Item_Name = Wanted then
                  return To_String (Items.Element (I).Value);
               end if;
            end;
         end loop;
      end if;

      raise Ada.IO_Exceptions.Data_Error
        with "config key does not exist: " & Name;
   end Get_Value;

   function Get_Text
     (Repo : Version.Repository.Repository_Handle; Name : String) return String
   is
   begin
      return Get_Value (Repo, Name) & Character'Val (10);
   end Get_Text;

   function List_Text
     (Repo : Version.Repository.Repository_Handle) return String
   is
      Items : constant Config_Entry_Vectors.Vector := Read_All (Repo);
      Text  : Unbounded_String;
   begin
      if not Items.Is_Empty then
         for I in Items.First_Index .. Items.Last_Index loop
            Append (Text, Config_Entry_Line (Items.Element (I)));
            Append (Text, Character'Val (10));
         end loop;
      end if;

      return To_String (Text);
   end List_Text;

   function Keys_Text
     (Repo : Version.Repository.Repository_Handle) return String
   is
      Items : constant Config_Entry_Vectors.Vector := Read_All (Repo);
      Text  : Unbounded_String;
   begin
      if not Items.Is_Empty then
         for I in Items.First_Index .. Items.Last_Index loop
            Append (Text, Config_Entry_Name (Items.Element (I)));
            Append (Text, Character'Val (10));
         end loop;
      end if;

      return To_String (Text);
   end Keys_Text;

   procedure Replace_Section
     (Repo    : Version.Repository.Repository_Handle;
      Section : String;
      Entries : Config_Entry_Vectors.Vector)
   is
      Existing : constant Config_Entry_Vectors.Vector := Read_All (Repo);

      Result : Config_Entry_Vectors.Vector;
   begin
      Require_Config_Section (Section);

      if not Existing.Is_Empty then
         for I in Existing.First_Index .. Existing.Last_Index loop
            declare
               Item : constant Config_Entry := Existing.Element (I);
            begin
               if Lower (To_String (Item.Section)) /= Lower (Section) then
                  Result.Append (Item);
               end if;
            end;
         end loop;
      end if;

      if not Entries.Is_Empty then
         for I in Entries.First_Index .. Entries.Last_Index loop
            Result.Append (Entries.Element (I));
         end loop;
      end if;

      Write_All (Repo => Repo, Entries => Result);
   end Replace_Section;

end Version.Config;
