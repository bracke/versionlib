with Ada.Characters.Latin_1;
with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Strings.Hash;
with Ada.Containers.Indefinite_Vectors;
with Ada.Directories;
with Ada.Strings.Fixed;

with Version.Config;
with Version.Files;
with Version.Ignore;

package body Version.Attributes is

   package String_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type   => Positive,
      Element_Type => String);

   --  One `<pattern> <attr>...` line, remembered with the directory it was
   --  written in (its patterns are relative to that).
   type Attr_Line is record
      Base_Dir : Unbounded_String;
      Pattern  : Unbounded_String;
      Tokens   : Unbounded_String;
   end record;

   package Line_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Attr_Line);

   type Macro is record
      Name   : Unbounded_String;
      Tokens : Unbounded_String;
   end record;

   package Macro_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Macro);

   Tab : constant Character := Ada.Characters.Latin_1.HT;

   function Is_Space (C : Character) return Boolean is
     (C = ' ' or else C = Tab);

   --  Split a line into whitespace-separated tokens.
   function Tokens_Of (Text : String) return String_Vectors.Vector is
      Result : String_Vectors.Vector;
      First  : Natural := Text'First;
   begin
      while First <= Text'Last loop
         while First <= Text'Last and then Is_Space (Text (First)) loop
            First := First + 1;
         end loop;

         exit when First > Text'Last;

         declare
            Last : Natural := First;
         begin
            while Last <= Text'Last and then not Is_Space (Text (Last)) loop
               Last := Last + 1;
            end loop;

            Result.Append (Text (First .. Last - 1));
            First := Last;
         end;
      end loop;

      return Result;
   end Tokens_Of;

   function Directory_Of (Path : String) return String is
      Slash : constant Natural :=
        Ada.Strings.Fixed.Index (Path, "/", Ada.Strings.Backward);
   begin
      return (if Slash = 0 then "" else Path (Path'First .. Slash - 1));
   end Directory_Of;

   --  Read one attributes file into Lines/Macros, keeping the order.  Base_Dir
   --  is the file's directory relative to the repository root.
   procedure Read_File
     (File_Path : String;
      Base_Dir  : String;
      Lines     : in out Line_Vectors.Vector;
      Macros    : in out Macro_Vectors.Vector;
      Names     : in out String_Vectors.Vector)
   is
      procedure Note_Names (Tokens : String) is
      begin
         for T of Tokens_Of (Tokens) loop
            declare
               Bare : constant String :=
                 (if T'Length > 0 and then T (T'First) in '-' | '!'
                  then T (T'First + 1 .. T'Last) else T);
               Equal : constant Natural := Ada.Strings.Fixed.Index (Bare, "=");
               Name  : constant String :=
                 (if Equal = 0 then Bare else Bare (Bare'First .. Equal - 1));
            begin
               if Name'Length > 0 and then not Names.Contains (Name) then
                  Names.Append (Name);
               end if;
            end;
         end loop;
      end Note_Names;

      Content : Unbounded_String;
      First   : Natural;
   begin
      if not Ada.Directories.Exists (File_Path) then
         return;
      end if;

      Content := To_Unbounded_String (Version.Files.Read_Binary_File (File_Path));

      declare
         Text : constant String := To_String (Content);
         Pos  : Natural := Text'First;
      begin
         while Pos <= Text'Last loop
            declare
               Stop : Natural :=
                 Ada.Strings.Fixed.Index (Text, "" & ASCII.LF, Pos);
               Line : constant String :=
                 Text (Pos .. (if Stop = 0 then Text'Last else Stop - 1));
               Trimmed : constant String :=
                 Ada.Strings.Fixed.Trim (Line, Ada.Strings.Both);
            begin
               if Stop = 0 then
                  Stop := Text'Last;
               end if;

               Pos := Stop + 1;

               if Trimmed'Length > 0 and then Trimmed (Trimmed'First) /= '#'
               then
                  First := Trimmed'First;

                  while First <= Trimmed'Last
                    and then not Is_Space (Trimmed (First))
                  loop
                     First := First + 1;
                  end loop;

                  declare
                     Head : constant String :=
                       Trimmed (Trimmed'First .. First - 1);
                     Rest : constant String :=
                       (if First > Trimmed'Last then ""
                        else Trimmed (First + 1 .. Trimmed'Last));
                  begin
                     if Head'Length > 6
                       and then Head (Head'First .. Head'First + 5) = "[attr]"
                     then
                        --  git registers the macro's own name before the
                        --  attributes it expands to; `-a` prints in exactly
                        --  that registration order.
                        Note_Names (Head (Head'First + 6 .. Head'Last));
                        Note_Names (Rest);

                        Macros.Append
                          (Macro'
                             (Name   => To_Unbounded_String
                                          (Head (Head'First + 6 .. Head'Last)),
                              Tokens => To_Unbounded_String (Rest)));
                     elsif Rest'Length > 0 then
                        Note_Names (Rest);

                        Lines.Append
                          (Attr_Line'
                             (Base_Dir => To_Unbounded_String (Base_Dir),
                              Pattern  => To_Unbounded_String (Head),
                              Tokens   => To_Unbounded_String (Rest)));
                     end if;
                  end;
               end if;
            end;
         end loop;
      end;
   end Read_File;

   --  Every attributes file that applies to Path, lowest precedence first:
   --  core.attributesFile, $GIT_DIR/info/attributes, then .gitattributes from
   --  the root down to Path's own directory.
   procedure Collect
     (Repo   : Version.Repository.Repository_Handle;
      Path   : String;
      Lines  : out Line_Vectors.Vector;
      Macros : out Macro_Vectors.Vector;
      Names  : out String_Vectors.Vector)
   is
      Root : constant String := Version.Repository.Root_Path (Repo);
   begin
      Lines.Clear;
      Macros.Clear;
      Names.Clear;

      --  git's built-in `binary` macro is registered before anything is read,
      --  its own name first and then the attributes it expands to.
      Names.Append ("binary");
      Names.Append ("diff");
      Names.Append ("merge");
      Names.Append ("text");

      if Version.Config.Has_Key (Repo, "core.attributesFile") then
         Read_File
           (Version.Config.Get_Value (Repo, "core.attributesFile"), "",
            Lines, Macros, Names);
      end if;

      Read_File
        (Version.Files.Join
           (Version.Files.Join
              (Version.Repository.Common_Git_Dir (Repo), "info"),
            "attributes"),
         "", Lines, Macros, Names);

      --  Root first, then each directory on the way down: a deeper file's
      --  lines come later and therefore win.
      Read_File (Version.Files.Join (Root, ".gitattributes"), "",
                 Lines, Macros, Names);

      declare
         Dir   : constant String := Directory_Of (Path);
         First : Natural := Dir'First;
      begin
         while First <= Dir'Last loop
            declare
               Slash : constant Natural :=
                 Ada.Strings.Fixed.Index (Dir (First .. Dir'Last), "/");
               Last  : constant Natural :=
                 (if Slash = 0 then Dir'Last else Slash - 1);
               Here  : constant String := Dir (Dir'First .. Last);
            begin
               Read_File
                 (Version.Files.Join
                    (Version.Files.Join (Root, Here), ".gitattributes"),
                  Here, Lines, Macros, Names);
               First := Last + 2;
            end;
         end loop;
      end;
   end Collect;

   --  git resolves a path's attributes highest-priority-first and only ever
   --  fills an attribute that is still *unknown* -- so the first assignment
   --  wins, and a `!attr` high up genuinely blocks a lower `attr`.  Within one
   --  line the tokens are walked in reverse for the same reason.  A macro is
   --  expanded only when it resolves to "set" (`!binary`/`-binary` therefore
   --  leave `diff`/`merge`/`text` alone) -- this is `macroexpand_one`.

   type Slot is record
      Known  : Boolean := False;
      Result : Attribute_Result;
   end record;

   package Slot_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type        => String,
      Element_Type    => Slot,
      Hash            => Ada.Strings.Hash,
      Equivalent_Keys => "=");

   procedure Split_Token
     (Token : String;
      Name  : out Unbounded_String;
      State : out Attribute_State;
      Value : out Unbounded_String)
   is
      Equal : constant Natural := Ada.Strings.Fixed.Index (Token, "=");
   begin
      Name := Null_Unbounded_String;
      State := Attribute_Unspecified;
      Value := Null_Unbounded_String;

      if Token'Length = 0 then
         return;
      end if;

      if Token (Token'First) = '-' then
         Name := To_Unbounded_String (Token (Token'First + 1 .. Token'Last));
         State := Attribute_Unset;
      elsif Token (Token'First) = '!' then
         Name := To_Unbounded_String (Token (Token'First + 1 .. Token'Last));
         State := Attribute_Unspecified;
      elsif Equal /= 0 then
         Name := To_Unbounded_String (Token (Token'First .. Equal - 1));
         State := Attribute_Valued;
         Value := To_Unbounded_String (Token (Equal + 1 .. Token'Last));
      else
         Name := To_Unbounded_String (Token);
         State := Attribute_Set;
      end if;
   end Split_Token;

   function Macro_Body
     (Macros : Macro_Vectors.Vector;
      Name   : String)
      return String
   is
   begin
      --  A later definition of the same macro overrides an earlier one.
      for I in reverse Macros.First_Index .. Macros.Last_Index loop
         if To_String (Macros.Element (I).Name) = Name then
            return To_String (Macros.Element (I).Tokens);
         end if;
      end loop;

      if Name = "binary" then
         return "-diff -merge -text";
      end if;

      return "";
   end Macro_Body;

   procedure Fill_Tokens
     (Tokens : String;
      Macros : Macro_Vectors.Vector;
      Slots  : in out Slot_Maps.Map;
      Depth  : Natural := 0)
   is
      Items : constant String_Vectors.Vector := Tokens_Of (Tokens);
   begin
      if Depth > 8 then
         return;
      end if;

      for I in reverse Items.First_Index .. Items.Last_Index loop
         declare
            Name  : Unbounded_String;
            State : Attribute_State;
            Value : Unbounded_String;
         begin
            Split_Token (Items.Element (I), Name, State, Value);

            if Name /= "" then
               declare
                  Key : constant String := To_String (Name);
               begin
                  if not Slots.Contains (Key)
                    or else not Slots.Element (Key).Known
                  then
                     Slots.Include
                       (Key,
                        Slot'(Known  => True,
                              Result => (State => State, Value => Value)));

                     if State = Attribute_Set then
                        declare
                           Expansion : constant String :=
                             Macro_Body (Macros, Key);
                        begin
                           if Expansion /= "" then
                              Fill_Tokens (Expansion, Macros, Slots, Depth + 1);
                           end if;
                        end;
                     end if;
                  end if;
               end;
            end if;
         end;
      end loop;
   end Fill_Tokens;

   --  git matches an attribute pattern literally: one containing a slash is
   --  anchored to the directory its `.gitattributes` sits in, one without
   --  matches the basename at any depth below it, and a pattern ending in '/'
   --  only ever matches a path spelled with a trailing '/'.  None of
   --  gitignore's "a directory carries its contents" behaviour applies.
   function Line_Applies
     (Item : Attr_Line;
      Path : String)
      return Boolean
   is
      Raw  : constant String := To_String (Item.Pattern);
      Base : constant String := To_String (Item.Base_Dir);

      Dir_Only : constant Boolean :=
        Raw'Length > 1 and then Raw (Raw'Last) = '/';

      Pattern : constant String :=
        (if Dir_Only then Raw (Raw'First .. Raw'Last - 1) else Raw);

      Path_Is_Dir : constant Boolean :=
        Path'Length > 0 and then Path (Path'Last) = '/';

      Target : constant String :=
        (if Path_Is_Dir then Path (Path'First .. Path'Last - 1) else Path);

      Anchored : Boolean := False;
      First    : Positive := Pattern'First;
   begin
      if Pattern'Length = 0 then
         return False;
      end if;

      if Dir_Only and then not Path_Is_Dir then
         return False;
      end if;

      if Pattern (First) = '/' then
         Anchored := True;
         First := First + 1;
      end if;

      for I in First .. Pattern'Last loop
         if Pattern (I) = '/' then
            Anchored := True;
            exit;
         end if;
      end loop;

      declare
         Body_Pattern : constant String := Pattern (First .. Pattern'Last);
      begin
         if Anchored then
            return Version.Ignore.Wildcard_Matches
              (Pattern =>
                 (if Base = "" then Body_Pattern
                  else Base & "/" & Body_Pattern),
               Text    => Target);
         end if;

         --  An unanchored pattern matches the basename, but only below the
         --  directory its file came from.
         if Base /= "" then
            if Target'Length <= Base'Length
              or else Target (Target'First .. Target'First + Base'Length - 1)
                      /= Base
              or else Target (Target'First + Base'Length) /= '/'
            then
               return False;
            end if;
         end if;

         declare
            Slash : constant Natural :=
              Ada.Strings.Fixed.Index (Target, "/", Ada.Strings.Backward);
            Simple : constant String :=
              (if Slash = 0 then Target
               else Target (Slash + 1 .. Target'Last));
         begin
            return Version.Ignore.Wildcard_Matches (Body_Pattern, Simple);
         end;
      end;
   end Line_Applies;

   --  Every attribute Path has, resolved.
   procedure Resolve
     (Repo  : Version.Repository.Repository_Handle;
      Path  : String;
      Slots : out Slot_Maps.Map;
      Names : out String_Vectors.Vector)
   is
      Lines  : Line_Vectors.Vector;
      Macros : Macro_Vectors.Vector;
   begin
      Slots.Clear;
      Collect (Repo, Path, Lines, Macros, Names);

      --  Highest priority first: the deepest file's last line.
      for I in reverse Lines.First_Index .. Lines.Last_Index loop
         if Line_Applies (Lines.Element (I), Path) then
            Fill_Tokens (To_String (Lines.Element (I).Tokens), Macros, Slots);
         end if;
      end loop;
   end Resolve;

   ------------
   -- Lookup --
   ------------

   function Lookup
     (Repo : Version.Repository.Repository_Handle;
      Path : String;
      Name : String)
      return Attribute_Result
   is
      Slots : Slot_Maps.Map;
      Names : String_Vectors.Vector;
   begin
      Resolve (Repo, Path, Slots, Names);

      if Slots.Contains (Name) and then Slots.Element (Name).Known then
         return Slots.Element (Name).Result;
      end if;

      return (State => Attribute_Unspecified, Value => <>);
   end Lookup;

   ------------------
   -- All_For_Path --
   ------------------

   function All_For_Path
     (Repo : Version.Repository.Repository_Handle;
      Path : String)
      return Named_Attribute_Vectors.Vector
   is
      Slots  : Slot_Maps.Map;
      Names  : String_Vectors.Vector;
      Result : Named_Attribute_Vectors.Vector;
   begin
      Resolve (Repo, Path, Slots, Names);

      --  Names comes back in git's registration order, which is the order
      --  `check-attr -a` prints in.
      for Name of Names loop
         if Slots.Contains (Name)
           and then Slots.Element (Name).Known
           and then Slots.Element (Name).Result.State /= Attribute_Unspecified
         then
            Result.Append
              (Named_Attribute'
                 (Name   => To_Unbounded_String (Name),
                  Result => Slots.Element (Name).Result));
         end if;
      end loop;

      return Result;
   end All_For_Path;

   -----------------
   -- State_Image --
   -----------------

   function State_Image (Result : Attribute_Result) return String is
   begin
      case Result.State is
         when Attribute_Set         => return "set";
         when Attribute_Unset       => return "unset";
         when Attribute_Unspecified => return "unspecified";
         when Attribute_Valued      => return To_String (Result.Value);
      end case;
   end State_Image;

end Version.Attributes;
