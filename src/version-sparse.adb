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

   package String_Sorting is new String_Vectors.Generic_Sorting;

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

      --  Cone-mode patterns (git's "/*", "!/*/", "/dir/") are not version
      --  pathspecs, so skip the pathspec-based positive-pattern validation.
      if Cone_Mode (Repo) then
         return True;
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

   --  Set core.sparseCheckout and core.sparseCheckoutCone in the local config,
   --  preserving other core entries and their order (git writes both keys).
   procedure Write_Core_Sparse_Config
     (Repo         : Version.Repository.Repository_Handle;
      Sparse_On    : Boolean;
      Cone_On      : Boolean)
   is
      Existing : constant Version.Config.Config_Entry_Vectors.Vector :=
        Version.Config.Read_All (Repo);
      Core     : Version.Config.Config_Entry_Vectors.Vector;
      Have_Sparse : Boolean := False;
      Have_Cone   : Boolean := False;

      function B (X : Boolean) return String is (if X then "true" else "false");

      procedure Emit (Key, Value : String) is
      begin
         Core.Append
           (Version.Config.Config_Entry'
              (Section => To_Unbounded_String ("core"),
               Key     => To_Unbounded_String (Key),
               Value   => To_Unbounded_String (Value)));
      end Emit;
   begin
      if not Existing.Is_Empty then
         for I in Existing.First_Index .. Existing.Last_Index loop
            declare
               Item    : constant Version.Config.Config_Entry :=
                 Existing.Element (I);
               Section : constant String := To_String (Item.Section);
               Key     : constant String := Lower_ASCII (To_String (Item.Key));
            begin
               if Lower_ASCII (Section) = "core" then
                  if Key = "sparsecheckout" then
                     if not Have_Sparse then
                        Have_Sparse := True;
                        Emit ("sparseCheckout", B (Sparse_On));
                     end if;
                  elsif Key = "sparsecheckoutcone" then
                     if not Have_Cone then
                        Have_Cone := True;
                        Emit ("sparseCheckoutCone", B (Cone_On));
                     end if;
                  else
                     Core.Append (Item);
                  end if;
               end if;
            end;
         end loop;
      end if;

      if not Have_Sparse then
         Emit ("sparseCheckout", B (Sparse_On));
      end if;
      if not Have_Cone then
         Emit ("sparseCheckoutCone", B (Cone_On));
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
      --  A raw ("--no-cone") pattern set turns cone mode off, as git does.
      Write_Core_Sparse_Config (Repo, Sparse_On => True, Cone_On => False);

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
   begin
      --  git keeps .git/info/sparse-checkout on disable and only clears the
      --  config flags, so a later `init`/`reapply` can reuse the patterns.
      Write_Core_Sparse_Config (Repo, Sparse_On => False, Cone_On => False);
   end Disable;

   --  git's cone-mode sparse-checkout (core.sparseCheckoutCone=true) is not a
   --  general pattern set but a set of "recursive" directories written as
   --  "/dir/" lines (plus the "/*" and "!/*/" boilerplate). Unlike version's
   --  own pathspec-based sparse patterns these are gitignore-anchored, so they
   --  are interpreted here directly by their cone semantics.
   function Cone_Mode
     (Repo : Version.Repository.Repository_Handle) return Boolean is
   begin
      declare
         V : constant String :=
           Version.Config.Get_Value (Repo, "core.sparseCheckoutCone");
      begin
         return V = "true" or else V = "1"
           or else V = "yes" or else V = "on";
      end;
   exception
      when others =>
         return False;
   end Cone_Mode;

   function Cone_Recursive_Directories
     (Repo : Version.Repository.Repository_Handle) return String_Vectors.Vector
   is
      Texts  : constant String_Vectors.Vector := Pattern_Texts (Repo);
      Result : String_Vectors.Vector;
   begin
      --  A "/dir/" line is a recursively-included (leaf) directory unless it
      --  is paired with a "!/dir/*/" exclusion, which marks it as an ancestor
      --  kept only for navigation. git's `list` prints just the leaves.
      for I in Texts.First_Index .. Texts.Last_Index loop
         declare
            T : constant String := Texts.Element (I);
         begin
            if T'Length >= 2
              and then T (T'First) = '/'
              and then T (T'Last) = '/'
            then
               declare
                  D : constant String := T (T'First + 1 .. T'Last - 1);
               begin
                  if not Contains_Text (Texts, "!/" & D & "/*/") then
                     Result.Append (D);
                  end if;
               end;
            end if;
         end;
      end loop;
      return Result;
   end Cone_Recursive_Directories;

   function Parent_Dir (P : String) return String is
   begin
      for K in reverse P'Range loop
         if P (K) = '/' then
            return P (P'First .. K - 1);
         end if;
      end loop;
      return "";
   end Parent_Dir;

   --  git cone inclusion, derived directly from the pattern lines: a path is
   --  included when its directory is the repository root, is a "parent" cone
   --  directory ("/D/" with a "!/D/*/" exclusion — whose own files stay but
   --  whose other subdirectories are excluded), or lies at or under a
   --  "recursive" cone directory ("/D/" without such an exclusion).
   function Cone_Included_By_Texts
     (Texts : String_Vectors.Vector; Path : String; Is_Directory : Boolean)
      return Boolean
   is
      D : constant String :=
        (if Is_Directory then Path else Parent_Dir (Path));

      function Present (S : String) return Boolean is (Contains_Text (Texts, S));

      function Is_Recursive (Dir : String) return Boolean is
        (Present ("/" & Dir & "/")
         and then not Present ("!/" & Dir & "/*/"));
   begin
      if D = "" then
         return True;
      end if;

      --  A parent directory's own direct files (not its other subdirectories).
      if Present ("/" & D & "/") and then Present ("!/" & D & "/*/") then
         return True;
      end if;

      --  D itself, or any ancestor of it, is a recursive directory.
      if Is_Recursive (D) then
         return True;
      end if;
      for K in reverse D'Range loop
         if D (K) = '/' and then Is_Recursive (D (D'First .. K - 1)) then
            return True;
         end if;
      end loop;

      return False;
   end Cone_Included_By_Texts;

   function Normalize_Cone_Dir (D : String) return String is
      F : Integer := D'First;
      L : Integer := D'Last;
   begin
      while F <= L and then D (F) = '/' loop
         F := F + 1;
      end loop;
      while L >= F and then D (L) = '/' loop
         L := L - 1;
      end loop;
      if F > L then
         return "";
      else
         return D (F .. L);
      end if;
   end Normalize_Cone_Dir;

   --  git's cone-pattern writer: the "/*" and "!/*/" boilerplate, then, for
   --  the sorted closure of the requested directories and all their ancestors,
   --  a "/D/" line (plus "!/D/*/" when D has a deeper directory in the set).
   function Cone_Patterns
     (Directories : String_Vectors.Vector) return String_Vectors.Vector
   is
      Closure : String_Vectors.Vector;
      Result  : String_Vectors.Vector;

      procedure Add_Unique (S : String) is
      begin
         if S /= "" and then not Contains_Text (Closure, S) then
            Closure.Append (S);
         end if;
      end Add_Unique;

      function Has_Descendant (D : String) return Boolean is
      begin
         for I in Closure.First_Index .. Closure.Last_Index loop
            declare
               E : constant String := Closure.Element (I);
            begin
               if E'Length > D'Length + 1
                 and then E (E'First .. E'First + D'Length) = D & "/"
               then
                  return True;
               end if;
            end;
         end loop;
         return False;
      end Has_Descendant;
   begin
      for I in Directories.First_Index .. Directories.Last_Index loop
         declare
            N : constant String := Normalize_Cone_Dir (Directories.Element (I));
         begin
            if N /= "" then
               for K in N'Range loop
                  if N (K) = '/' then
                     Add_Unique (N (N'First .. K - 1));
                  end if;
               end loop;
               Add_Unique (N);
            end if;
         end;
      end loop;

      String_Sorting.Sort (Closure);

      Result.Append ("/*");
      Result.Append ("!/*/");
      for I in Closure.First_Index .. Closure.Last_Index loop
         declare
            D : constant String := Closure.Element (I);
         begin
            Result.Append ("/" & D & "/");
            if Has_Descendant (D) then
               Result.Append ("!/" & D & "/*/");
            end if;
         end;
      end loop;

      return Result;
   end Cone_Patterns;

   procedure Set_Cone
     (Repo        : Version.Repository.Repository_Handle;
      Directories : String_Vectors.Vector)
   is
      Path      : constant String := Sparse_Path (Repo);
      Temp_Path : constant String := Path & ".tmp";
      File      : Ada.Text_IO.File_Type;
      Patterns  : String_Vectors.Vector;
   begin
      for I in Directories.First_Index .. Directories.Last_Index loop
         declare
            N : constant String := Normalize_Cone_Dir (Directories.Element (I));
         begin
            if N /= "" then
               Version.Path_Safety.Require_Safe_Relative_Path
                 (N, "sparse cone directory");
            end if;
         end;
      end loop;

      Patterns := Cone_Patterns (Directories);

      Version.Files.Create_Parent_Directories (Temp_Path);
      Ada.Text_IO.Create
        (File, Ada.Text_IO.Out_File, Version.Files.To_Native_Path (Temp_Path));
      for I in Patterns.First_Index .. Patterns.Last_Index loop
         Ada.Text_IO.Put_Line (File, Patterns.Element (I));
      end loop;
      Ada.Text_IO.Close (File);
      Version.Files.Atomic_Replace (Temp_Path, Path);
      Write_Core_Sparse_Config (Repo, Sparse_On => True, Cone_On => True);

   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         Version.Files.Delete_File_If_Exists (Temp_Path);
         raise;
   end Set_Cone;

   function Included
     (Repo         : Version.Repository.Repository_Handle;
      Path         : String;
      Is_Directory : Boolean := False) return Boolean is
   begin
      --  When sparse checkout is off every path is included; validate only
      --  when a decision actually depends on the pattern set (callers such as
      --  status pass administrative paths like ".git" that must not raise).
      if not Enabled (Repo) then
         return True;
      end if;

      --  Administrative paths (e.g. ".git") are never part of the sparse set;
      --  treat them as excluded rather than raising, matching the previous
      --  pathspec-match behaviour.
      begin
         Version.Path_Safety.Require_Safe_Relative_Path (Path, "sparse path");
      exception
         when others =>
            return False;
      end;

      if Cone_Mode (Repo) then
         return
           Cone_Included_By_Texts (Pattern_Texts (Repo), Path, Is_Directory);
      end if;

      return
        Version.Pathspec.Matches_Any
          (Items        => Patterns (Repo),
           Path         => Path,
           Is_Directory => Is_Directory);
   end Included;

end Version.Sparse;
