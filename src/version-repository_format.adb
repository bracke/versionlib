with Ada.Directories; use Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Strings;
with Ada.Strings.Fixed;
with Ada.Text_IO;

with Version.Unsupported;

with Version.Files;

package body Version.Repository_Format is

   use Ada.Strings.Unbounded;

   function Join
     (Left  : String;
      Right : String)
      return String renames Version.Files.Join;

   function Is_Blank
     (C : Character)
      return Boolean
   is
   begin
      return C = ' '
        or else C = Character'Val (9)
        or else C = Character'Val (10)
        or else C = Character'Val (13);
   end Is_Blank;

   function Trim
     (Value : String)
      return String
   is
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

   function Strip_Inline_Comment
     (Line : String)
      return String
   is
      In_Quote : Boolean := False;
   begin
      for I in Line'Range loop
         if Line (I) = '"' then
            In_Quote := not In_Quote;
         elsif not In_Quote
           and then (Line (I) = '#' or else Line (I) = ';')
           and then (I = Line'First or else Is_Blank (Line (I - 1)))
         then
            if I = Line'First then
               return "";
            else
               return Line (Line'First .. I - 1);
            end if;
         end if;
      end loop;

      return Line;
   end Strip_Inline_Comment;

   function Lower
     (Value : String)
      return String
   is
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

   function Unquote
     (Value : String)
      return String
   is
      Text : constant String := Trim (Value);
   begin
      if Text'Length >= 2
        and then Text (Text'First) = '"'
        and then Text (Text'Last) = '"'
      then
         return Text (Text'First + 1 .. Text'Last - 1);
      end if;

      return Text;
   end Unquote;

   function Section_Name
     (Line : String)
      return String
   is
      Text : constant String := Trim (Line);
   begin
      if Text'Length < 2
        or else Text (Text'First) /= '['
        or else Text (Text'Last) /= ']'
      then
         return "";
      end if;

      return Lower (Trim (Text (Text'First + 1 .. Text'Last - 1)));
   end Section_Name;

   function Boolean_Value
     (Value   : String;
      Context : String)
      return Boolean
   is
      Text : constant String := Lower (Trim (Unquote (Value)));
   begin
      if Text = "true" or else Text = "yes" or else Text = "on" or else Text = "1" then
         return True;
      elsif Text = "false" or else Text = "no" or else Text = "off" or else Text = "0" then
         return False;
      else
         raise Ada.IO_Exceptions.Data_Error with "invalid " & Context & ": " & Text;
      end if;
   end Boolean_Value;

   procedure Require_Config_Scalar
     (Value   : String;
      Context : String)
   is
   begin
      for C of Value loop
         if C = Character'Val (0)
           or else C = Character'Val (10)
           or else C = Character'Val (13)
           or else (Character'Pos (C) < 32 and then C /= Character'Val (9))
           or else Character'Pos (C) = 127
         then
            raise Ada.IO_Exceptions.Data_Error with
              Context & " contains an unsafe control character";
         end if;
      end loop;
   end Require_Config_Scalar;

   procedure Set_Unsupported
     (Info   : in out Format_Info;
      Reason : String)
   is
   begin
      if Info.Level /= Unsupported then
         Info.Level := Unsupported;
         Info.Reason := To_Unbounded_String (Reason);
      end if;
   end Set_Unsupported;

   function Parse_Natural
     (Value   : String;
      Context : String)
      return Natural
   is
      Text : constant String := Trim (Unquote (Value));
   begin
      if Text'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with Context & " must not be empty";
      end if;

      for C of Text loop
         if C not in '0' .. '9' then
            raise Ada.IO_Exceptions.Data_Error with "invalid " & Context & ": " & Text;
         end if;
      end loop;

      begin
         return Natural'Value (Text);
      exception
         when Constraint_Error =>
            raise Ada.IO_Exceptions.Data_Error with
              "invalid " & Context & ": " & Text;
      end;
   end Parse_Natural;

   function Default_Info return Format_Info is
   begin
      return
        (Repository_Format_Version => 0,
         Object_Format             => To_Unbounded_String ("sha1"),
         Ref_Storage               => To_Unbounded_String ("files"),
         Worktree_Config           => False,
         Partial_Clone_Remote      => Null_Unbounded_String,
         Level                     => Compatible,
         Reason                    => Null_Unbounded_String);
   end Default_Info;

   procedure Apply_Entry
     (Info    : in out Format_Info;
      Section : String;
      Key     : String;
      Value   : String)
   is
      Section_Lower : constant String := Lower (Trim (Section));
      Key_Lower     : constant String := Lower (Trim (Key));
      Value_Text    : constant String := Trim (Unquote (Value));
   begin
      Require_Config_Scalar (Value_Text, "repository format value");

      if Section_Lower = "core" and then Key_Lower = "repositoryformatversion" then
         Info.Repository_Format_Version :=
           Parse_Natural (Value_Text, "repository format version");

      elsif Section_Lower = "extensions" then
         if Key_Lower = "objectformat" then
            Info.Object_Format := To_Unbounded_String (Lower (Value_Text));

         elsif Key_Lower = "refstorage" then
            Info.Ref_Storage := To_Unbounded_String (Lower (Value_Text));

         elsif Key_Lower = "worktreeconfig" then
            Info.Worktree_Config := Boolean_Value (Value_Text, "repository extension worktreeConfig");

         elsif Key_Lower = "partialclone" then
            Info.Partial_Clone_Remote := To_Unbounded_String (Value_Text);

         else
            Set_Unsupported (Info, "unsupported repository extension: " & Trim (Key));
         end if;
      end if;
   end Apply_Entry;

   procedure Finalize_Compatibility
     (Info : in out Format_Info)
   is
      Object_Format : constant String := To_String (Info.Object_Format);
      Ref_Storage   : constant String := To_String (Info.Ref_Storage);
   begin
      if Info.Repository_Format_Version > 1 then
         Set_Unsupported
           (Info,
            "unsupported repository format version: "
            & Ada.Strings.Fixed.Trim (Natural'Image (Info.Repository_Format_Version), Ada.Strings.Both));
      end if;

      if Object_Format /= "sha1" and then Object_Format /= "sha256" then
         --  SHA-1 and SHA-256 are both supported (the object/index/pack/ref
         --  machinery is width-aware — see docs/SHA256_SCOPE.md). Any other
         --  object format is genuinely unknown and rejected.
         Set_Unsupported (Info, Version.Unsupported.Object_Format (Object_Format));
      end if;

      if Ref_Storage /= "files" and then Ref_Storage /= "reftable" then
         --  "files" and "reftable" are both supported (reftable is read via
         --  Version.Reftable and written via Version.Reftable.Writer). Any
         --  other backend is genuinely unknown and rejected.
         Set_Unsupported (Info, Version.Unsupported.Ref_Storage (Ref_Storage));
      end if;

      --  extensions.worktreeConfig is supported: the per-worktree
      --  config.worktree is layered over the common config when reading
      --  configuration (see Version.Config.Read_All).
   end Finalize_Compatibility;

   function Read
     (Git_Dir : String)
      return Format_Info
   is
      Path            : constant String := Join (Git_Dir, "config");
      File            : Ada.Text_IO.File_Type;
      Info            : Format_Info := Default_Info;
      Current_Section : Unbounded_String;
   begin
      if Git_Dir'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with "repository git dir must not be empty";
      end if;

      if not Ada.Directories.Exists (Version.Files.To_Native_Path (Path)) then
         return Info;
      end if;

      if Ada.Directories.Kind (Version.Files.To_Native_Path (Path)) /=
        Ada.Directories.Ordinary_File
      then
         raise Ada.IO_Exceptions.Data_Error with "repository config is not a file";
      end if;

      Ada.Text_IO.Open
        (File,
         Ada.Text_IO.In_File,
         Version.Files.To_Native_Path (Path));

      while not Ada.Text_IO.End_Of_File (File) loop
         declare
            Line : constant String := Ada.Text_IO.Get_Line (File);
            Text : constant String := Trim (Strip_Inline_Comment (Line));
         begin
            if Text'Length = 0 then
               null;

            elsif Text (Text'First) = '#' or else Text (Text'First) = ';' then
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
                     Apply_Entry
                       (Info    => Info,
                        Section => To_String (Current_Section),
                        Key     => Text (Text'First .. Eq_Pos - 1),
                        Value   => Text (Eq_Pos + 1 .. Text'Last));
                  else
                     --  Git config permits key-only boolean entries.  They must not
                     --  bypass extension compatibility checks.
                     Apply_Entry
                       (Info    => Info,
                        Section => To_String (Current_Section),
                        Key     => Text,
                        Value   => "true");
                  end if;
               end;
            end if;
         end;
      end loop;

      Ada.Text_IO.Close (File);
      Finalize_Compatibility (Info);
      return Info;

   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;

         raise;
   end Read;

   procedure Require_Compatible
     (Git_Dir  : String;
      Mutation : Boolean := True)
   is
      pragma Unreferenced (Mutation);
      Info : constant Format_Info := Read (Git_Dir);
   begin
      if not Is_Supported (Info) then
         raise Ada.IO_Exceptions.Data_Error with To_String (Info.Reason);
      end if;
   end Require_Compatible;

   function Is_Supported
     (Info : Format_Info)
      return Boolean
   is
   begin
      return Info.Level = Compatible;
   end Is_Supported;

   function Algorithm
     (Info : Format_Info)
      return Version.Hash.Hash_Algorithm
   is
   begin
      if To_String (Info.Object_Format) = "sha256" then
         return Version.Hash.Sha256;
      else
         return Version.Hash.Sha1;
      end if;
   end Algorithm;

end Version.Repository_Format;
