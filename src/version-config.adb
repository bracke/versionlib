with Ada.Calendar;
with Ada.Calendar.Time_Zones;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;
with Ada.Text_IO;

with Version.Files;
with Version.Refs;

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
   --  Unquoted trailing whitespace is dropped and unquoted interior runs are
   --  preserved only when a value char follows (git's pending-space rule), so
   --  whitespace protected by double quotes survives a write/read round-trip.
   function Decode_Config_Value (Raw : String) return String is
      Result   : String (1 .. Raw'Length);
      Len      : Natural := 0;
      In_Quote : Boolean := False;
      Pending  : Natural := 0;
      I        : Natural := Raw'First;

      procedure Emit (C : Character) is
      begin
         --  Flush any deferred unquoted whitespace now that a value char
         --  follows it; trailing unquoted whitespace is never flushed.
         while Pending > 0 loop
            Len := Len + 1;
            Result (Len) := ' ';
            Pending := Pending - 1;
         end loop;
         Len := Len + 1;
         Result (Len) := C;
      end Emit;
   begin
      while I <= Raw'Last loop
         declare
            C : constant Character := Raw (I);
         begin
            if C = '"' then
               In_Quote := not In_Quote;
               I := I + 1;
            elsif C = '\' and then I < Raw'Last then
               case Raw (I + 1) is
                  when 'n' => Emit (Character'Val (10));
                  when 't' => Emit (Character'Val (9));
                  when 'b' => Emit (Character'Val (8));
                  when others => Emit (Raw (I + 1));
               end case;
               I := I + 2;
            elsif (not In_Quote) and then (C = '#' or else C = ';') then
               exit;
            elsif (not In_Quote)
              and then (C = ' ' or else C = Character'Val (9))
            then
               Pending := Pending + 1;
               I := I + 1;
            else
               Emit (C);
               I := I + 1;
            end if;
         end;
      end loop;
      return Result (1 .. Len);
   end Decode_Config_Value;

   --  Serialize a value the way git's quote_value does: always escape \, ",
   --  tab and newline; wrap the whole value in double quotes when it has a
   --  leading or trailing space or contains a comment introducer (# or ;).
   function Quote_Config_Value (Value : String) return String is
      Buf   : Unbounded_String;
      Quote : Boolean :=
        Value'Length > 0
          and then (Value (Value'First) = ' '
                    or else Value (Value'Last) = ' ');
   begin
      for C of Value loop
         if C = '#' or else C = ';' then
            Quote := True;
         end if;
      end loop;

      for C of Value loop
         case C is
            when '"' =>
               Append (Buf, '\');
               Append (Buf, '"');
            when '\' =>
               Append (Buf, '\');
               Append (Buf, '\');
            when Character'Val (9) =>
               Append (Buf, "\t");
            when Character'Val (10) =>
               Append (Buf, "\n");
            when others =>
               Append (Buf, C);
         end case;
      end loop;

      if Quote then
         return '"' & To_String (Buf) & '"';
      else
         return To_String (Buf);
      end if;
   end Quote_Config_Value;

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
   function Starts_With (S, P : String) return Boolean is
     (S'Length >= P'Length
      and then S (S'First .. S'First + P'Length - 1) = P);

   --  Expand a leading "~/" (or bare "~") to $HOME; leave anything else as-is.
   function Expand_Tilde (P : String) return String is
   begin
      if P'Length >= 1
        and then P (P'First) = '~'
        and then (P'Length = 1 or else P (P'First + 1) = '/')
        and then Ada.Environment_Variables.Exists ("HOME")
        and then Ada.Environment_Variables.Value ("HOME")'Length > 0
      then
         return Version.Files.Join
           (Ada.Environment_Variables.Value ("HOME"),
            (if P'Length = 1 then "" else P (P'First + 2 .. P'Last)));
      else
         return P;
      end if;
   end Expand_Tilde;

   --  Resolve an include "path" value: "~" -> $HOME, absolute stays, otherwise
   --  relative to the directory of the including config file (git semantics).
   function Resolve_Include_Path
     (Config_Path : String; Value : String) return String is
   begin
      if Value'Length = 0 then
         return "";
      elsif Value (Value'First) = '~' then
         return Expand_Tilde (Value);
      elsif Value (Value'First) = '/' then
         return Value;
      elsif Config_Path'Length = 0 then
         return Value;
      else
         return Version.Files.Join
           (Ada.Directories.Containing_Directory (Config_Path), Value);
      end if;
   end Resolve_Include_Path;

   --  wildmatch with pathname semantics: '*'/'?' never cross '/', but '**'
   --  does. "**/" matches zero or more leading path components; a trailing
   --  "**" matches everything remaining.
   function Glob_Match (Pattern, Text : String) return Boolean is
      function M (P, T : Natural) return Boolean is
      begin
         if P > Pattern'Last then
            return T > Text'Last;
         end if;

         if Pattern (P) = '*' then
            if P + 1 <= Pattern'Last and then Pattern (P + 1) = '*' then
               --  "**"
               if P + 2 <= Pattern'Last and then Pattern (P + 2) = '/' then
                  --  "**/": zero components, or consume through any '/'.
                  if M (P + 3, T) then
                     return True;
                  end if;
                  for K in T .. Text'Last loop
                     if Text (K) = '/' and then M (P + 3, K + 1) then
                        return True;
                     end if;
                  end loop;
                  return False;
               else
                  --  trailing/other "**": match any remaining span.
                  for K in T .. Text'Last + 1 loop
                     if M (P + 2, K) then
                        return True;
                     end if;
                  end loop;
                  return False;
               end if;
            else
               --  single '*': match zero or more non-'/' characters.
               for K in T .. Text'Last + 1 loop
                  if M (P + 1, K) then
                     return True;
                  end if;
                  exit when K > Text'Last or else Text (K) = '/';
               end loop;
               return False;
            end if;

         elsif Pattern (P) = '?' then
            return T <= Text'Last and then Text (T) /= '/'
              and then M (P + 1, T + 1);
         else
            return T <= Text'Last and then Text (T) = Pattern (P)
              and then M (P + 1, T + 1);
         end if;
      end M;
   begin
      return M (Pattern'First, Text'First);
   end Glob_Match;

   --  Normalise a gitdir: condition pattern per git: expand "~", make "./"
   --  relative to the config file, prepend "**/" when unrooted, and append
   --  "**" when it ends in '/'.
   function Normalize_Gitdir_Pattern
     (Raw : String; Config_Path : String) return String
   is
      function Add_Trailing (S : String) return String is
        (if S'Length > 0 and then S (S'Last) = '/' then S & "**" else S);
   begin
      if Raw'Length = 0 then
         return "";
      elsif Raw (Raw'First) = '~' then
         return Add_Trailing (Expand_Tilde (Raw));
      elsif Starts_With (Raw, "./") then
         if Config_Path'Length > 0 then
            return Add_Trailing
              (Version.Files.Join
                 (Ada.Directories.Containing_Directory (Config_Path),
                  Raw (Raw'First + 2 .. Raw'Last)));
         else
            return Add_Trailing (Raw (Raw'First + 2 .. Raw'Last));
         end if;
      elsif Raw (Raw'First) = '/' then
         return Add_Trailing (Raw);
      else
         return Add_Trailing ("**/" & Raw);
      end if;
   end Normalize_Gitdir_Pattern;

   function Lower_Str (S : String) return String renames Lower;

   --  Evaluate whether an "[include]" / "[includeIf \"...\"]" section applies.
   function Include_Applies
     (Repo        : Version.Repository.Repository_Handle;
      Section     : String;
      Config_Path : String;
      So_Far      : Config_Entry_Vectors.Vector) return Boolean
   is
      Sect : constant String := Trim (Section);
      Low  : constant String := Lower_Str (Sect);
   begin
      if Low = "include" then
         return True;
      end if;

      if not Starts_With (Low, "includeif") then
         return False;
      end if;

      --  Extract the quoted condition, e.g. includeIf "gitdir:/x" -> gitdir:/x
      declare
         Q1 : Natural := 0;
         Q2 : Natural := 0;
      begin
         for I in Sect'Range loop
            if Sect (I) = '"' then
               if Q1 = 0 then
                  Q1 := I;
               else
                  Q2 := I;
               end if;
            end if;
         end loop;

         if Q1 = 0 or else Q2 <= Q1 + 1 then
            return False;
         end if;

         declare
            Cond : constant String := Sect (Q1 + 1 .. Q2 - 1);
         begin
            if Starts_With (Cond, "gitdir:")
              or else Starts_With (Cond, "gitdir/i:")
            then
               declare
                  Ci      : constant Boolean := Starts_With (Cond, "gitdir/i:");
                  Raw     : constant String :=
                    Cond (Cond'First + (if Ci then 9 else 7) .. Cond'Last);
                  Pat     : constant String :=
                    Normalize_Gitdir_Pattern (Raw, Config_Path);
                  Git_Dir : constant String :=
                    Version.Files.Normalize_Separators
                      (Version.Repository.Git_Dir (Repo));
               begin
                  if Ci then
                     return Glob_Match (Lower_Str (Pat), Lower_Str (Git_Dir));
                  else
                     return Glob_Match (Pat, Git_Dir);
                  end if;
               end;

            elsif Starts_With (Cond, "onbranch:") then
               declare
                  Raw    : constant String :=
                    Cond (Cond'First + 9 .. Cond'Last);
                  Pat    : constant String :=
                    (if Raw'Length > 0 and then Raw (Raw'Last) = '/'
                     then Raw & "**" else Raw);
                  Branch : constant String :=
                    Version.Refs.Current_Branch_Name (Repo);
               begin
                  return Branch'Length > 0 and then Glob_Match (Pat, Branch);
               end;

            elsif Starts_With (Cond, "hasconfig:remote.*.url:") then
               declare
                  Pat : constant String :=
                    Cond (Cond'First + 23 .. Cond'Last);
               begin
                  for E of So_Far loop
                     declare
                        Name : constant String :=
                          Lower_Str (Config_Entry_Name (E));
                     begin
                        if Starts_With (Name, "remote.")
                          and then Name'Length > 4
                          and then Name (Name'Last - 3 .. Name'Last) = ".url"
                          and then Glob_Match
                                     (Pat, To_String (E.Value))
                        then
                           return True;
                        end if;
                     end;
                  end loop;
                  return False;
               end;
            else
               return False;
            end if;
         end;
      end;
   end Include_Applies;

   procedure Append_Config_File
     (Path   : String;
      Result : in out Config_Entry_Vectors.Vector;
      Repo   : access constant Version.Repository.Repository_Handle := null;
      Depth  : Natural := 0)
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
                     declare
                        Key : constant String :=
                          Trim (Text (Text'First .. Eq_Pos - 1));
                        Val : constant String :=
                          Decode_Config_Value
                            (Trim (Text (Eq_Pos + 1 .. Text'Last)));
                        Sect : constant String :=
                          Lower_Str (To_String (Current_Section));
                     begin
                        --  git keeps the include/includeIf directive itself as
                        --  a readable config key ("include.path", etc.) whether
                        --  or not it applies, so always record it.
                        Result.Append
                          (Config_Entry'
                             (Section => Current_Section,
                              Key     => To_Unbounded_String (Key),
                              Value   => To_Unbounded_String (Val)));

                        --  When reading the effective config (Repo present),
                        --  additionally expand the included file inline at this
                        --  point if the directive applies. Bounded to guard
                        --  against include cycles (git's default depth limit).
                        if Repo /= null
                          and then Lower_Str (Key) = "path"
                          and then (Sect = "include"
                                    or else Starts_With (Sect, "includeif"))
                          and then Depth < 10
                          and then Include_Applies
                                     (Repo.all, To_String (Current_Section),
                                      Path, Result)
                        then
                           Append_Config_File
                             (Resolve_Include_Path (Path, Val),
                              Result, Repo, Depth + 1);
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

   function Env_Value (Name : String) return String is
     (if Ada.Environment_Variables.Exists (Name)
      then Ada.Environment_Variables.Value (Name) else "");

   --  git_env_bool-style truthiness (used for GIT_CONFIG_NOSYSTEM): set to
   --  anything other than a false-ish word counts as enabled.
   function Env_Flag_Set (Name : String) return Boolean is
      V : constant String := Lower (Env_Value (Name));
   begin
      return Ada.Environment_Variables.Exists (Name)
        and then V /= "0" and then V /= "false"
        and then V /= "no" and then V /= "off";
   end Env_Flag_Set;

   --  System-scope config file: GIT_CONFIG_SYSTEM overrides the compiled-in
   --  /etc/gitconfig; GIT_CONFIG_NOSYSTEM suppresses it entirely.
   function System_Config_File return String is
   begin
      if Env_Flag_Set ("GIT_CONFIG_NOSYSTEM") then
         return "";
      elsif Ada.Environment_Variables.Exists ("GIT_CONFIG_SYSTEM") then
         return Env_Value ("GIT_CONFIG_SYSTEM");
      else
         return "/etc/gitconfig";
      end if;
   end System_Config_File;

   --  XDG global config (`$XDG_CONFIG_HOME/git/config`, else
   --  `$HOME/.config/git/config`), read before ~/.gitconfig.
   function Xdg_Global_Config_File return String is
   begin
      if Env_Value ("XDG_CONFIG_HOME") /= "" then
         return
           Version.Files.Join (Env_Value ("XDG_CONFIG_HOME"), "git/config");
      elsif Env_Value ("HOME") /= "" then
         return Version.Files.Join (Env_Value ("HOME"), ".config/git/config");
      else
         return "";
      end if;
   end Xdg_Global_Config_File;

   function Home_Global_Config_File return String is
     (if Env_Value ("HOME") /= ""
      then Version.Files.Join (Env_Value ("HOME"), ".gitconfig") else "");

   function Read_All
     (Repo : Version.Repository.Repository_Handle)
      return Config_Entry_Vectors.Vector
   is
      R      : aliased constant Version.Repository.Repository_Handle := Repo;
      Result : Config_Entry_Vectors.Vector;

      procedure Read (Path : String) is
      begin
         --  An empty path means the scope is absent/suppressed (e.g. HOME
         --  unset, or GIT_CONFIG_NOSYSTEM); skip it. (Ada.Directories rejects
         --  "" with Name_Error, so guard before touching the filesystem.)
         if Path /= "" then
            Append_Config_File (Path, Result, R'Access);
         end if;
      end Read;
   begin
      --  git's config read order (last value wins): system, then global
      --  (XDG then ~/.gitconfig, or GIT_CONFIG_GLOBAL replacing both), then
      --  the repository's local config, then the per-worktree config.
      Read (System_Config_File);

      if Ada.Environment_Variables.Exists ("GIT_CONFIG_GLOBAL") then
         Read (Env_Value ("GIT_CONFIG_GLOBAL"));
      else
         Read (Xdg_Global_Config_File);
         Read (Home_Global_Config_File);
      end if;

      Read (Config_Path (Repo));

      if Worktree_Config_Enabled (Result) then
         --  config.worktree is read after the common config (git order), so
         --  its entries append and last-match lookups resolve to the
         --  per-worktree value.
         Read
           (Version.Files.Join
              (Version.Repository.Git_Dir (Repo), "config.worktree"));
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
                  & Quote_Config_Value (To_String (Item.Value)));
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
            --  git canonicalises the section and variable names to lower case
            --  but preserves the (case-sensitive) subsection verbatim.
            if Base'Length > 0 and then Sub'Length > 0 then
               return Lower (Base) & "." & Sub & "." & Lower (Key);
            end if;
         end;
      end if;

      return Lower (Section) & "." & Lower (Key);
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
      Matches : Natural := 0;
   begin
      Require_Config_Name (Name);

      if not Items.Is_Empty then
         for I in Items.First_Index .. Items.Last_Index loop
            declare
               Item      : constant Config_Entry := Items.Element (I);
               Item_Name : constant String := Lower (Config_Entry_Name (Item));
            begin
               if Item_Name = Wanted then
                  Matches := Matches + 1;
               else
                  Result.Append (Item);
               end if;
            end;
         end loop;
      end if;

      if Matches = 0 then
         raise Ada.IO_Exceptions.Data_Error
           with "config key does not exist: " & Name;
      elsif Matches > 1 then
         --  Ambiguous: git refuses a single-value unset of a multivar and
         --  leaves every value in place. Do not write Result.
         raise Ambiguous_Key with Name & " has multiple values";
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
      Found  : Boolean := False;
      Value  : Unbounded_String;
   begin
      Require_Config_Name (Name);

      --  git resolves a single-valued lookup to the LAST occurrence in read
      --  order (local then included/worktree entries), so keep scanning and
      --  remember the most recent match rather than returning the first.
      if not Items.Is_Empty then
         for I in Items.First_Index .. Items.Last_Index loop
            declare
               Item_Name : constant String :=
                 Lower (Config_Entry_Name (Items.Element (I)));
            begin
               if Item_Name = Wanted then
                  Found := True;
                  Value := Items.Element (I).Value;
               end if;
            end;
         end loop;
      end if;

      if Found then
         return To_String (Value);
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

   ---------------------
   -- Normalize_Date --
   ---------------------

   function Normalize_Date (Text : String) return String is

      function Digits_Only (S : String) return Boolean is
        (S'Length > 0
         and then (for all C of S => C in '0' .. '9'));

      function Zone (S : String) return String is
      begin
         --  "+0200", "+02:00", or nothing (git then assumes UTC).
         if S'Length = 0 then
            return "+0000";
         elsif S'Length = 5 and then S (S'First) in '+' | '-' then
            return S;
         elsif S'Length = 6 and then S (S'First) in '+' | '-'
           and then S (S'First + 3) = ':'
         then
            return S (S'First .. S'First + 2) & S (S'First + 4 .. S'Last);
         else
            return "";
         end if;
      end Zone;

      Trimmed : constant String :=
        Ada.Strings.Fixed.Trim (Text, Ada.Strings.Both);
   begin
      if Trimmed'Length = 0 then
         return "";
      end if;

      declare
         Head  : constant String :=
           (if Trimmed (Trimmed'First) = '@'
            then Trimmed (Trimmed'First + 1 .. Trimmed'Last) else Trimmed);
         Space : constant Natural :=
           Ada.Strings.Fixed.Index (Head, " ");
         Left  : constant String :=
           (if Space = 0 then Head else Head (Head'First .. Space - 1));
         Right : constant String :=
           (if Space = 0 then ""
            else Ada.Strings.Fixed.Trim
                   (Head (Space + 1 .. Head'Last), Ada.Strings.Both));
      begin
         --  "<seconds> <+-hhmm>": already git's own spelling.
         if Digits_Only (Left) and then Zone (Right) /= "" then
            return Left & " " & Zone (Right);
         end if;

         --  ISO 8601: "YYYY-MM-DD HH:MM:SS +hhmm" (or with a 'T', or with the
         --  zone glued to the seconds).
         if Head'Length >= 19
           and then Head (Head'First + 4) = '-'
           and then Head (Head'First + 7) = '-'
           and then Head (Head'First + 13) = ':'
         then
            declare
               Stamp : constant String :=
                 Head (Head'First .. Head'First + 18);
               Rest  : constant String :=
                 Ada.Strings.Fixed.Trim
                   (Head (Head'First + 19 .. Head'Last), Ada.Strings.Both);
               Off   : constant String := Zone (Rest);

               Epoch : constant Ada.Calendar.Time :=
                 Ada.Calendar.Time_Of (1970, 1, 1);

               When_Utc : Ada.Calendar.Time;
               Secs     : Integer;
            begin
               if Off = "" then
                  return "";
               end if;

               When_Utc :=
                 Ada.Calendar.Time_Of
                   (Year    => Integer'Value (Stamp (Stamp'First
                                              .. Stamp'First + 3)),
                    Month   => Integer'Value (Stamp (Stamp'First + 5
                                              .. Stamp'First + 6)),
                    Day     => Integer'Value (Stamp (Stamp'First + 8
                                              .. Stamp'First + 9)),
                    Seconds =>
                      Duration
                        (Integer'Value
                           (Stamp (Stamp'First + 11 .. Stamp'First + 12))
                         * 3600
                         + Integer'Value
                             (Stamp (Stamp'First + 14 .. Stamp'First + 15))
                           * 60
                         + Integer'Value
                             (Stamp (Stamp'First + 17 .. Stamp'First + 18))));

               Secs := Integer (Ada.Calendar."-" (When_Utc, Epoch));

               --  The stamp is local to Off; git stores UTC seconds.
               Secs := Secs
                 - (Integer'Value (Off (Off'First + 1 .. Off'First + 2)) * 3600
                    + Integer'Value (Off (Off'First + 3 .. Off'Last)) * 60)
                   * (if Off (Off'First) = '-' then -1 else 1);

               return Ada.Strings.Fixed.Trim
                        (Integer'Image (Secs), Ada.Strings.Both)
                      & " " & Off;
            exception
               when others =>
                  return "";
            end;
         end if;

         return "";
      end;
   end Normalize_Date;

   --  "+hhmm" for the local timezone, as git records it.
   function Local_Zone return String is
      Offset : constant Integer :=
        Integer (Ada.Calendar.Time_Zones.UTC_Time_Offset);

      Sign  : constant Character := (if Offset < 0 then '-' else '+');
      Total : constant Natural := abs Offset;

      function Pad (V : Natural) return String is
         Image : constant String := Natural'Image (V);
         Text  : constant String := Image (Image'First + 1 .. Image'Last);
      begin
         return (if Text'Length = 1 then "0" & Text else Text);
      end Pad;
   begin
      return Sign & Pad (Total / 60) & Pad (Total mod 60);
   exception
      when others =>
         return "+0000";
   end Local_Zone;

   function Now_Stamp return String is
      Epoch : constant Ada.Calendar.Time := Ada.Calendar.Time_Of (1970, 1, 1);
      Secs  : constant Integer :=
        Integer (Ada.Calendar."-" (Ada.Calendar.Clock, Epoch));
   begin
      return Ada.Strings.Fixed.Trim (Integer'Image (Secs), Ada.Strings.Both)
             & " " & Local_Zone;
   end Now_Stamp;

   function Env (Name : String) return String is
     (if Ada.Environment_Variables.Exists (Name)
      then Ada.Environment_Variables.Value (Name) else "");

   function Signature
     (Repo   : Version.Repository.Repository_Handle;
      Prefix : String)
      return String
   is
      User : constant Identity := User_Identity (Repo);

      Name : constant String :=
        (if Env (Prefix & "_NAME") /= "" then Env (Prefix & "_NAME")
         else To_String (User.Name));

      Email : constant String :=
        (if Env (Prefix & "_EMAIL") /= "" then Env (Prefix & "_EMAIL")
         else To_String (User.Email));

      Stamp : constant String := Normalize_Date (Env (Prefix & "_DATE"));
   begin
      return Name & " <" & Email & "> "
             & (if Stamp = "" then Now_Stamp else Stamp);
   end Signature;

   function Committer_Timestamp return String is
      Stamp : constant String := Normalize_Date (Env ("GIT_COMMITTER_DATE"));
   begin
      return (if Stamp = "" then Now_Stamp else Stamp);
   end Committer_Timestamp;

   function Author_Signature
     (Repo : Version.Repository.Repository_Handle)
      return String
   is (Signature (Repo, "GIT_AUTHOR"));

   function Committer_Signature
     (Repo : Version.Repository.Repository_Handle)
      return String
   is (Signature (Repo, "GIT_COMMITTER"));

end Version.Config;
