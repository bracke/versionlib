with Ada.Containers.Ordered_Sets;
with Ada.Containers.Vectors;
with Ada.Directories; use Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Strings.Unbounded;

with Version.Objects; use Version.Objects;
with Version.Object_Cache;
with Version.Tree_Cache;
with Version.Compression;
with Version.Files;
with Version.Pretty_Format;
with Version.Revisions;
with Version.Tar;
with Version.Zip;

package body Version.Archive is

   use Ada.Strings.Unbounded;

   package String_Sets is new Ada.Containers.Ordered_Sets
     (Element_Type => Unbounded_String);

   --  git archive emits entries in a single recursive tree-order stream: a
   --  directory entry appears immediately before its contents, interleaved
   --  with sibling files -- not all directories first. Merging directory and
   --  file entries into one list keyed by the archive path (directories keyed
   --  with a trailing '/', which is how git sorts a tree) reproduces it.
   type Emit_Kind is (Emit_Directory, Emit_Content);
   type Emit_Item is record
      Kind     : Emit_Kind := Emit_Content;
      Sort_Key : Unbounded_String;
      Dir_Path : Unbounded_String;   --  Emit_Directory: the "dir/" path
      Entry_Ix : Natural := 0;       --  Emit_Content: Selected_Entries index
   end record;

   package Emit_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Emit_Item);

   function Emit_Less (Left, Right : Emit_Item) return Boolean is
     (Left.Sort_Key < Right.Sort_Key);

   package Emit_Sorting is new Emit_Vectors.Generic_Sorting
     ("<" => Emit_Less);

   function Unsupported_Output_Format_Text (Output : String) return String is
   begin
      return "unsupported archive output format: " & Output
        & " (supported outputs end in .tar, .tar.gz, .tgz, or .zip; "
        & "use --format tar|tar.gz|zip)";
   end Unsupported_Output_Format_Text;

   function Is_Regular_Mode (Mode : String) return Boolean is
   begin
      return Mode = "100644";
   end Is_Regular_Mode;

   function Is_Executable_Mode (Mode : String) return Boolean is
   begin
      return Mode = "100755";
   end Is_Executable_Mode;

   function Is_Symlink_Mode (Mode : String) return Boolean is
   begin
      return Mode = "120000";
   end Is_Symlink_Mode;

   function Parent_Of (Path : String) return String is
   begin
      for I in reverse Path'Range loop
         if Path (I) = '/' then
            if I = Path'First then
               return "";
            else
               return Path (Path'First .. I - 1);
            end if;
         end if;
      end loop;
      return "";
   end Parent_Of;

   procedure Append_Parents
     (Dirs : in out String_Sets.Set;
      Path : String)
   is
      Parent : constant String := Parent_Of (Path);
   begin
      if Parent'Length = 0 then
         return;
      end if;

      Append_Parents (Dirs, Parent);
      Dirs.Include (To_Unbounded_String (Parent));
   end Append_Parents;

   function Selected
     (Path      : String;
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector)
      return Boolean
   is
   begin
      return Version.Pathspec.Matches_Any (Pathspecs, Path, False);
   end Selected;

   function Gitlink_Content
     (Id : Version.Objects.Hex_Object_Id)
      return String
   is
   begin
      return "Submodule: " & To_String (Id) & Character'Val (10);
   end Gitlink_Content;

   function Is_Disallowed_Control (C : Character) return Boolean is
   begin
      return Character'Pos (C) < 32 or else Character'Pos (C) = 127;
   end Is_Disallowed_Control;

   procedure Validate_Prefix_Component
     (Full_Prefix : String;
      Component   : String)
   is
   begin
      if Component'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with
           "empty archive prefix component in prefix: " & Full_Prefix;
      elsif Component = "." or else Component = ".." or else Component = ".git" then
         raise Ada.IO_Exceptions.Data_Error with
           "unsafe archive prefix component """ & Component & """: " & Full_Prefix;
      end if;
   end Validate_Prefix_Component;

   function Normalize_Prefix (Prefix : String) return String is
      Start : Natural;
      Stop  : Natural;
   begin
      if Prefix'Length = 0 then
         return "";
      elsif Prefix (Prefix'First) = '/' then
         raise Ada.IO_Exceptions.Data_Error with "absolute archive prefix rejected: " & Prefix;
      end if;

      for C of Prefix loop
         if C = '\' or else C = Character'Val (0) then
            raise Ada.IO_Exceptions.Data_Error with "invalid archive prefix: " & Prefix;
         elsif Is_Disallowed_Control (C) then
            raise Ada.IO_Exceptions.Data_Error with "archive prefix contains control character";
         end if;
      end loop;

      Start := Prefix'First;
      while Start <= Prefix'Last loop
         Stop := Start;
         while Stop <= Prefix'Last and then Prefix (Stop) /= '/' loop
            Stop := Stop + 1;
         end loop;

         if Stop = Start then
            if Stop /= Prefix'Last then
               raise Ada.IO_Exceptions.Data_Error with
                 "empty archive prefix component in prefix: " & Prefix;
            end if;
         else
            Validate_Prefix_Component (Prefix, Prefix (Start .. Stop - 1));
         end if;

         Start := Stop + 1;
      end loop;

      if Prefix (Prefix'Last) = '/' then
         if Prefix'Length = 1 then
            raise Ada.IO_Exceptions.Data_Error with
              "empty archive prefix component in prefix: " & Prefix;
         end if;
         return Prefix (Prefix'First .. Prefix'Last - 1);
      else
         return Prefix;
      end if;
   end Normalize_Prefix;

   function With_Prefix
     (Prefix : String;
      Path   : String)
      return String
   is
   begin
      if Prefix'Length = 0 then
         return Path;
      elsif Path'Length = 0 then
         return Prefix;
      else
         return Prefix & "/" & Path;
      end if;
   end With_Prefix;

   function Ends_With
     (Text   : String;
      Suffix : String)
      return Boolean
   is
   begin
      return Text'Length >= Suffix'Length
        and then Text (Text'Last - Suffix'Length + 1 .. Text'Last) = Suffix;
   end Ends_With;

   function Lower_ASCII (Text : String) return String is
      Result : String := Text;
   begin
      for I in Result'Range loop
         if Result (I) >= 'A' and then Result (I) <= 'Z' then
            Result (I) := Character'Val
              (Character'Pos (Result (I)) - Character'Pos ('A') + Character'Pos ('a'));
         end if;
      end loop;
      return Result;
   end Lower_ASCII;

   function Looks_Like_Unsupported_Archive_Output
     (Path : String)
      return Boolean
   is
      Lower : constant String := Lower_ASCII (Path);
   begin
      return Ends_With (Lower, ".tar.xz")
        or else Ends_With (Lower, ".txz")
        or else Ends_With (Lower, ".xz")
        or else Ends_With (Lower, ".tar.bz2")
        or else Ends_With (Lower, ".tbz")
        or else Ends_With (Lower, ".tbz2")
        or else Ends_With (Lower, ".bz2")
        or else Ends_With (Lower, ".zipx")
        or else Ends_With (Lower, ".7z")
        or else Ends_With (Lower, ".rar");
   end Looks_Like_Unsupported_Archive_Output;

   procedure Validate_Output_Path (Output : String) is
      Normalized : constant String := Version.Files.Normalize_Separators (Output);
      Native     : constant String := Version.Files.To_Native_Path (Output);
   begin
      if Output'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with "archive output path is empty";
      end if;

      for C of Output loop
         if C = Character'Val (0) then
            raise Ada.IO_Exceptions.Data_Error with "archive output path contains NUL";
         end if;
      end loop;

      if Normalized'Length > 0
        and then Normalized (Normalized'Last) = '/'
      then
         raise Ada.IO_Exceptions.Data_Error with
           "archive output path names a directory: " & Output;
      end if;

      if Looks_Like_Unsupported_Archive_Output (Normalized) then
         raise Ada.IO_Exceptions.Data_Error with
           Unsupported_Output_Format_Text (Output);
      end if;

      if Ada.Directories.Exists (Native)
        and then Ada.Directories.Kind (Native) = Ada.Directories.Directory
      then
         raise Ada.IO_Exceptions.Data_Error with
           "archive output path names a directory: " & Output;
      end if;
   end Validate_Output_Path;

   procedure Remove_Partial_Output (Output : String) is
      Native : constant String := Version.Files.To_Native_Path (Output);
   begin
      if Output'Length > 0 and then Ada.Directories.Exists (Native)
        and then Ada.Directories.Kind (Native) = Ada.Directories.Ordinary_File
      then
         Ada.Directories.Delete_File (Native);
      end if;
   exception
      when others =>
         null;
   end Remove_Partial_Output;

   function Temp_Output_Path (Output : String) return String is
   begin
      return Output & ".version-archive-tmp";
   end Temp_Output_Path;

   --------------------------------------------------------------------------
   --  export-subst: keyword substitution in archived blobs
   --------------------------------------------------------------------------
   --
   --  git expands `$Format:<pretty>$` in files carrying the `export-subst`
   --  attribute, using the commit being archived. Attributes are sourced from
   --  the archived tree's own `.gitattributes` files (nested, deeper wins) and
   --  `.git/info/attributes` (highest), NOT the working tree.

   LF : constant Character := Character'Val (10);

   type Subst_Rule is record
      Base_Dir : Unbounded_String;   --  repo-relative dir of the .gitattributes
      Pattern  : Unbounded_String;
      Pathname : Boolean := False;    --  pattern contains a slash
      Set      : Boolean := True;     --  True = export-subst, False = -export-subst
   end record;

   package Subst_Rule_Vectors is new Ada.Containers.Vectors
     (Positive, Subst_Rule);

   type Subst_Context is record
      Rules     : Subst_Rule_Vectors.Vector;
      Commit_Id : Version.Objects.Object_Id_Storage;
      Active    : Boolean := False;   --  any export-subst rule + a real commit
   end record;

   --  Shell-style glob; when Pathname, '*' does not cross '/'. (Mirrors
   --  Version.Text_Filter's matcher so archive attribute globs behave the same.)
   function Subst_Glob (Pat, Text : String; Pathname : Boolean) return Boolean is
      function M (Pi, Ti : Integer) return Boolean is
         P : Integer := Pi;
         T : Integer := Ti;
      begin
         while P <= Pat'Last loop
            case Pat (P) is
               when '?' =>
                  if T > Text'Last
                    or else (Pathname and then Text (T) = '/')
                  then
                     return False;
                  end if;
                  P := P + 1;
                  T := T + 1;
               when '*' =>
                  P := P + 1;
                  for K in T .. Text'Last + 1 loop
                     if M (P, K) then
                        return True;
                     end if;
                     exit when K > Text'Last
                       or else (Pathname and then Text (K) = '/');
                  end loop;
                  return False;
               when others =>
                  if T > Text'Last or else Text (T) /= Pat (P) then
                     return False;
                  end if;
                  P := P + 1;
                  T := T + 1;
            end case;
         end loop;
         return T > Text'Last;
      end M;
   begin
      return M (Pat'First, Text'First);
   end Subst_Glob;

   function Subst_Base_Name (Path : String) return String is
      Slash : Natural := 0;
   begin
      for I in Path'Range loop
         if Path (I) = '/' then
            Slash := I;
         end if;
      end loop;
      return (if Slash = 0 then Path else Path (Slash + 1 .. Path'Last));
   end Subst_Base_Name;

   function Subst_Matches (R : Subst_Rule; Path : String) return Boolean is
      Pat  : constant String := To_String (R.Pattern);
      Base : constant String := To_String (R.Base_Dir);

      function Match_Rel (Rel : String) return Boolean is
      begin
         if R.Pathname then
            return Subst_Glob (Pat, Rel, Pathname => True);
         else
            return Subst_Glob (Pat, Subst_Base_Name (Rel), Pathname => False);
         end if;
      end Match_Rel;
   begin
      if Base'Length = 0 then
         return Match_Rel (Path);
      end if;
      if Path'Length <= Base'Length + 1
        or else Path (Path'First .. Path'First + Base'Length - 1) /= Base
        or else Path (Path'First + Base'Length) /= '/'
      then
         return False;
      end if;
      return Match_Rel (Path (Path'First + Base'Length + 1 .. Path'Last));
   end Subst_Matches;

   --  Parse one `.gitattributes` line for an export-subst (or -export-subst)
   --  setting, appending a rule when present.
   procedure Parse_Subst_Line
     (Line     : String;
      Base_Dir : String;
      Rules    : in out Subst_Rule_Vectors.Vector)
   is
      First : Natural := Line'First;
      Last  : Natural := Line'Last;
   begin
      --  Trim surrounding whitespace and CR.
      while First <= Last
        and then (Line (First) = ' ' or else Line (First) = Character'Val (9))
      loop
         First := First + 1;
      end loop;
      while Last >= First
        and then (Line (Last) = ' ' or else Line (Last) = Character'Val (9)
                  or else Line (Last) = Character'Val (13))
      loop
         Last := Last - 1;
      end loop;
      if First > Last or else Line (First) = '#' then
         return;
      end if;
      --  First token is the pattern.
      declare
         Pat_End : Natural := First;
         Set     : Boolean := False;
         Seen    : Boolean := False;
         Tok     : Natural;
      begin
         while Pat_End <= Last
           and then Line (Pat_End) /= ' '
           and then Line (Pat_End) /= Character'Val (9)
         loop
            Pat_End := Pat_End + 1;
         end loop;
         declare
            Pattern : constant String := Line (First .. Pat_End - 1);
            Has_Slash : Boolean := False;
         begin
            --  Remaining tokens: look for export-subst / -export-subst.
            Tok := Pat_End;
            while Tok <= Last loop
               while Tok <= Last
                 and then (Line (Tok) = ' '
                           or else Line (Tok) = Character'Val (9))
               loop
                  Tok := Tok + 1;
               end loop;
               exit when Tok > Last;
               declare
                  Tok_End : Natural := Tok;
               begin
                  while Tok_End <= Last
                    and then Line (Tok_End) /= ' '
                    and then Line (Tok_End) /= Character'Val (9)
                  loop
                     Tok_End := Tok_End + 1;
                  end loop;
                  declare
                     A : constant String := Line (Tok .. Tok_End - 1);
                  begin
                     if A = "export-subst" then
                        Set := True;
                        Seen := True;
                     elsif A = "-export-subst" or else A = "!export-subst" then
                        Set := False;
                        Seen := True;
                     end if;
                  end;
                  Tok := Tok_End;
               end;
            end loop;
            if not Seen then
               return;
            end if;
            for C of Pattern loop
               if C = '/' then
                  Has_Slash := True;
               end if;
            end loop;
            --  A leading '/' anchors to Base_Dir; drop it (pattern already
            --  matched relative to the base).
            declare
               P0 : constant String :=
                 (if Pattern'Length > 0 and then Pattern (Pattern'First) = '/'
                  then Pattern (Pattern'First + 1 .. Pattern'Last)
                  else Pattern);
            begin
               Rules.Append
                 (Subst_Rule'
                    (Base_Dir => To_Unbounded_String (Base_Dir),
                     Pattern  => To_Unbounded_String (P0),
                     Pathname => Has_Slash,
                     Set      => Set));
            end;
         end;
      end;
   end Parse_Subst_Line;

   procedure Load_Subst_Attr_Content
     (Content  : String;
      Base_Dir : String;
      Rules    : in out Subst_Rule_Vectors.Vector)
   is
      Start : Natural := Content'First;
   begin
      for I in Content'Range loop
         if Content (I) = LF then
            Parse_Subst_Line (Content (Start .. I - 1), Base_Dir, Rules);
            Start := I + 1;
         end if;
      end loop;
      if Start <= Content'Last then
         Parse_Subst_Line (Content (Start .. Content'Last), Base_Dir, Rules);
      end if;
   end Load_Subst_Attr_Content;

   function Has_Export_Subst
     (Rules : Subst_Rule_Vectors.Vector;
      Path  : String)
      return Boolean
   is
      Result : Boolean := False;
   begin
      for R of Rules loop
         if Subst_Matches (R, Path) then
            Result := R.Set;
         end if;
      end loop;
      return Result;
   end Has_Export_Subst;

   --  Replace every `$Format:<pretty>$` with the expanded pretty format for
   --  the archived commit. A `$Format:` with no closing `$` is left intact.
   function Expand_Format_Subst
     (Content   : String;
      Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id)
      return String
   is
      Marker : constant String := "$Format:";
      Result : Unbounded_String;
      I      : Natural := Content'First;
   begin
      while I <= Content'Last loop
         if I + Marker'Length - 1 <= Content'Last
           and then Content (I .. I + Marker'Length - 1) = Marker
         then
            --  Find the closing '$'.
            declare
               J : Natural := I + Marker'Length;
            begin
               while J <= Content'Last and then Content (J) /= '$' loop
                  J := J + 1;
               end loop;
               if J <= Content'Last then
                  Append
                    (Result,
                     Version.Pretty_Format.Expand
                       (Repo, Commit_Id,
                        Content (I + Marker'Length .. J - 1)));
                  I := J + 1;
               else
                  --  No closing '$': emit the rest verbatim.
                  Append (Result, Content (I .. Content'Last));
                  I := Content'Last + 1;
               end if;
            end;
         else
            Append (Result, Content (I));
            I := I + 1;
         end if;
      end loop;
      return To_String (Result);
   end Expand_Format_Subst;

   --  Build the export-subst context from the archived tree's attribute files
   --  (root and nested `.gitattributes`, then `.git/info/attributes`) and the
   --  commit being archived.
   procedure Build_Subst_Context
     (Repository : Version.Repository.Repository_Handle;
      Revision   : String;
      Entries    : Version.Objects.Tree_Entry_Vectors.Vector;
      Cache      : in out Version.Object_Cache.Object_Cache;
      Context    : out Subst_Context)
   is
      --  Attribute files ordered shallow-to-deep so deeper rules win.
      procedure Add_Attr_Files (Max_Depth : Natural) is
      begin
         for I in Entries.First_Index .. Entries.Last_Index loop
            declare
               E    : constant Version.Objects.Tree_Entry := Entries.Element (I);
               Path : constant String := To_String (E.Path);
            begin
               if E.Kind = Version.Objects.Tree_Blob
                 and then (Path = ".gitattributes"
                           or else
                             (Path'Length >= 15
                              and then Path (Path'Last - 14 .. Path'Last)
                                       = "/.gitattributes"))
               then
                  declare
                     Dir : constant String := Parent_Of (Path);
                     Depth : Natural := 0;
                  begin
                     for C of Dir loop
                        if C = '/' then
                           Depth := Depth + 1;
                        end if;
                     end loop;
                     if Dir'Length > 0 then
                        Depth := Depth + 1;
                     end if;
                     if Depth = Max_Depth then
                        declare
                           Obj : constant Version.Objects.Git_Object :=
                             Version.Object_Cache.Read_Object
                               (Repository, Cache, E.Id);
                        begin
                           Load_Subst_Attr_Content
                             (Version.Objects.Content (Obj), Dir,
                              Context.Rules);
                        end;
                     end if;
                  end;
               end if;
            end;
         end loop;
      end Add_Attr_Files;

      Max_Depth : Natural := 0;
   begin
      --  Determine the deepest .gitattributes directory to bound the passes.
      for I in Entries.First_Index .. Entries.Last_Index loop
         declare
            Path : constant String := To_String (Entries.Element (I).Path);
            Depth : Natural := 0;
         begin
            if Path = ".gitattributes"
              or else (Path'Length >= 15
                       and then Path (Path'Last - 14 .. Path'Last)
                                = "/.gitattributes")
            then
               for C of Parent_Of (Path) loop
                  if C = '/' then
                     Depth := Depth + 1;
                  end if;
               end loop;
               if Parent_Of (Path)'Length > 0 then
                  Depth := Depth + 1;
               end if;
               if Depth > Max_Depth then
                  Max_Depth := Depth;
               end if;
            end if;
         end;
      end loop;
      for D in 0 .. Max_Depth loop
         Add_Attr_Files (D);
      end loop;

      --  .git/info/attributes has the highest precedence.
      declare
         Info : constant String :=
           Version.Files.Join
             (Version.Files.Join
                (Version.Repository.Git_Dir (Repository), "info"),
              "attributes");
      begin
         if Version.Files.Is_Ordinary_File (Info) then
            Load_Subst_Attr_Content
              (Version.Files.Read_Binary_File (Info), "", Context.Rules);
         end if;
      end;

      Context.Active := not Context.Rules.Is_Empty;
      if Context.Active then
         begin
            Context.Commit_Id :=
              Version.Revisions.Resolve_Commit (Repository, Revision);
         exception
            when others =>
               --  Not a commit (e.g. a bare tree): nothing to substitute.
               Context.Active := False;
         end;
      end if;
   end Build_Subst_Context;

   --  The blob content to archive for Path, with export-subst applied when the
   --  path carries the attribute.
   function Archive_Blob_Content
     (Repository : Version.Repository.Repository_Handle;
      Context    : Subst_Context;
      Path       : String;
      Raw        : String)
      return String
   is
   begin
      if Context.Active and then Has_Export_Subst (Context.Rules, Path) then
         return Expand_Format_Subst (Raw, Repository, Context.Commit_Id);
      else
         return Raw;
      end if;
   end Archive_Blob_Content;

   --  git archive stamps every tar entry with the archived commit's committer
   --  time. Return that epoch (the second-to-last whitespace token of the
   --  "committer " line), or 0 when the revision is a bare tree.
   function Committer_Epoch
     (Repository : Version.Repository.Repository_Handle;
      Commit_Id  : Version.Objects.Hex_Object_Id) return Natural
   is
      Obj     : constant Version.Objects.Git_Object :=
        Version.Objects.Read_Object (Repository, Commit_Id);
      Content : constant String := Version.Objects.Content (Obj);
      Pos     : Natural := Content'First;
   begin
      while Pos <= Content'Last loop
         declare
            Stop : Natural := Pos;
         begin
            while Stop <= Content'Last
              and then Content (Stop) /= Character'Val (10)
            loop
               Stop := Stop + 1;
            end loop;
            declare
               Line : constant String := Content (Pos .. Stop - 1);
            begin
               if Line'Length > 10
                 and then Line (Line'First .. Line'First + 9) = "committer "
               then
                  declare
                     Last_Sp : Natural := 0;
                     Prev_Sp : Natural := 0;
                  begin
                     for I in reverse Line'Range loop
                        if Line (I) = ' ' then
                           if Last_Sp = 0 then
                              Last_Sp := I;
                           else
                              Prev_Sp := I;
                              exit;
                           end if;
                        end if;
                     end loop;
                     if Prev_Sp /= 0 and then Last_Sp > Prev_Sp then
                        return Natural'Value (Line (Prev_Sp + 1 .. Last_Sp - 1));
                     end if;
                  end;
               end if;
            end;
            Pos := Stop + 1;
         end;
      end loop;
      return 0;
   exception
      when others =>
         return 0;
   end Committer_Epoch;

   procedure Create
     (Repository : Version.Repository.Repository_Handle;
      Revision   : String;
      Output     : String;
      Format     : Archive_Format := Tar_Format)
   is
      Empty : Version.Pathspec.Pathspec_Vectors.Vector;
   begin
      Create
        (Repository => Repository,
         Revision   => Revision,
         Output     => Output,
         Format     => Format,
         Pathspecs  => Empty);
   end Create;

   procedure Create
     (Repository : Version.Repository.Repository_Handle;
      Revision   : String;
      Output     : String;
      Format     : Archive_Format;
      Pathspecs  : Version.Pathspec.Pathspec_Vectors.Vector)
   is
   begin
      Create
        (Repository => Repository,
         Revision   => Revision,
         Output     => Output,
         Format     => Format,
         Pathspecs  => Pathspecs,
         Prefix     => "");
   end Create;

   procedure Create
     (Repository : Version.Repository.Repository_Handle;
      Revision   : String;
      Output     : String;
      Format     : Archive_Format;
      Pathspecs  : Version.Pathspec.Pathspec_Vectors.Vector;
      Prefix     : String)
   is
      Tree_Id : Version.Objects.Object_Id_Storage;
      Entries          : Version.Objects.Tree_Entry_Vectors.Vector;
      Selected_Entries : Version.Objects.Tree_Entry_Vectors.Vector;
      Dirs             : String_Sets.Set;
      Emission         : Emit_Vectors.Vector;
      Object_Cache : Version.Object_Cache.Object_Cache;
      Tree_Cache   : Version.Tree_Cache.Tree_Cache;
      Archive_Prefix : constant String := Normalize_Prefix (Prefix);
      Work_Output    : constant String := Temp_Output_Path (Output);
      Subst          : Subst_Context;
   begin
      Validate_Output_Path (Output);
      Version.Files.Require_Reasonable_Path_Length (Output);
      Version.Files.Require_Reasonable_Path_Length (Work_Output);
      Remove_Partial_Output (Work_Output);

      if Revision'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with "archive revision is empty";
      end if;

      begin
         Tree_Id := Version.Revisions.Resolve_Tree (Repository, Revision);
      exception
         when Ada.IO_Exceptions.Data_Error | Constraint_Error =>
            raise Ada.IO_Exceptions.Data_Error with "revision not found: " & Revision;
      end;

      Entries := Version.Tree_Cache.Flatten_Tree (Repository, Tree_Cache, Tree_Id);

      Build_Subst_Context
        (Repository, Revision, Entries, Object_Cache, Subst);

      if Archive_Prefix'Length > 0 then
         Dirs.Include (To_Unbounded_String (Archive_Prefix));
      end if;

      if not Entries.Is_Empty then
         for I in Entries.First_Index .. Entries.Last_Index loop
            declare
               Current_Entry        : constant Version.Objects.Tree_Entry := Entries.Element (I);
               Path         : constant String := To_String (Current_Entry.Path);
               Archive_Path : constant String := With_Prefix (Archive_Prefix, Path);
            begin
               if Selected (Path, Pathspecs) then
                  Selected_Entries.Append (Current_Entry);
                  Append_Parents (Dirs, Archive_Path);
               end if;
            end;
         end loop;
      end if;

      --  Merge directories and files into a single git-tree-ordered stream:
      --  each directory keyed with a trailing '/' (so it sorts immediately
      --  before its contents), each file keyed by its archive path.
      for Dir of Dirs loop
         declare
            D   : constant String := To_String (Dir);
            Key : constant String :=
              (if D'Length > 0 and then D (D'Last) = '/' then D else D & "/");
            --  git emits the whole --prefix as a single directory entry; the
            --  prefix's own intermediate components (e.g. "x/" for prefix
            --  "x/y/") are not separate entries. Skip those proper ancestors.
            Ancestor_Of_Prefix : constant Boolean :=
              Archive_Prefix'Length > 0
              and then Key'Length < Archive_Prefix'Length
              and then Archive_Prefix
                         (Archive_Prefix'First
                          .. Archive_Prefix'First + Key'Length - 1) = Key;
         begin
            if not Ancestor_Of_Prefix then
               Emission.Append
                 (Emit_Item'
                    (Kind     => Emit_Directory,
                     Sort_Key => To_Unbounded_String (Key),
                     Dir_Path => To_Unbounded_String (Key),
                     Entry_Ix => 0));
            end if;
         end;
      end loop;
      for I in Selected_Entries.First_Index .. Selected_Entries.Last_Index loop
         Emission.Append
           (Emit_Item'
              (Kind     => Emit_Content,
               Sort_Key =>
                 To_Unbounded_String
                   (With_Prefix
                      (Archive_Prefix,
                       To_String (Selected_Entries.Element (I).Path))),
               Dir_Path => Null_Unbounded_String,
               Entry_Ix => I));
      end loop;
      Emit_Sorting.Sort (Emission);

      case Format is
         when Tar_Format | Tar_Gz_Format =>
            declare
               Writer     : Version.Tar.Tar_Writer;
               Commit     : Version.Objects.Hex_Object_Id;
               Has_Commit : Boolean := True;
               Mtime      : Natural := 0;
            begin
               --  Resolve the commit first: its committer time stamps every
               --  tar entry, and its id goes in the pax global header.
               begin
                  Commit :=
                    Version.Revisions.Resolve_Commit (Repository, Revision);
               exception
                  when others =>
                     Has_Commit := False;
               end;
               if Has_Commit then
                  Mtime := Committer_Epoch (Repository, Commit);
               end if;

               Version.Tar.Create (Writer, Work_Output, Mtime);

               --  git archive prepends a pax global header carrying the
               --  commit id when the revision is a commit-ish (not a bare
               --  tree); `get-tar-commit-id` reads it back.
               if Has_Commit then
                  Version.Tar.Add_Pax_Global_Header
                    (Writer, Version.Objects.To_String (Commit));
               end if;

               for Item of Emission loop
                  if Item.Kind = Emit_Directory then
                     Version.Tar.Add_Directory
                       (Writer, To_String (Item.Dir_Path));
                  else
                     declare
                        Current_Entry : constant Version.Objects.Tree_Entry :=
                          Selected_Entries.Element (Item.Entry_Ix);
                        Path         : constant String :=
                          To_String (Current_Entry.Path);
                        Archive_Path : constant String :=
                          With_Prefix (Archive_Prefix, Path);
                     begin
                        if Current_Entry.Kind = Version.Objects.Tree_Gitlink then
                              Version.Tar.Add_File
                                (Writer, Archive_Path, Gitlink_Content (Current_Entry.Id), False);
                        elsif Current_Entry.Kind = Version.Objects.Tree_Blob then
                              declare
                                 Obj : constant Version.Objects.Git_Object :=
                                   Version.Object_Cache.Read_Object (Repository, Object_Cache, Current_Entry.Id);
                              begin
                                 if Version.Objects.Kind (Obj) /= Version.Objects.Blob_Object then
                                    raise Ada.IO_Exceptions.Data_Error with
                                      "archive entry is not a blob: " & Path;
                                 end if;

                                 if Is_Symlink_Mode (To_String (Current_Entry.Mode)) then
                                    Version.Tar.Add_Symlink
                                      (Writer, Archive_Path, Version.Objects.Content (Obj));
                                 elsif Is_Regular_Mode (To_String (Current_Entry.Mode))
                                   or else Is_Executable_Mode (To_String (Current_Entry.Mode))
                                 then
                                    Version.Tar.Add_File
                                      (Writer,
                                       Archive_Path,
                                       Archive_Blob_Content
                                         (Repository, Subst, Path,
                                          Version.Objects.Content (Obj)),
                                       Is_Executable_Mode (To_String (Current_Entry.Mode)));
                                 else
                                    raise Ada.IO_Exceptions.Data_Error with
                                      "unsupported archive file mode "
                                      & To_String (Current_Entry.Mode) & ": " & Path;
                                 end if;
                              end;
                        end if;
                     end;
                  end if;
               end loop;

               Version.Tar.Close (Writer);
               if Format = Tar_Gz_Format then
                  --  Compress the finished tar into a gzip member.
                  declare
                     Tar_Bytes : constant String :=
                       Version.Files.Read_Binary_File (Work_Output);
                  begin
                     Version.Files.Write_Binary_File
                       (Output, Version.Compression.Gzip (Tar_Bytes));
                     Remove_Partial_Output (Work_Output);
                  end;
               else
                  Version.Files.Atomic_Replace (Work_Output, Output);
               end if;
            exception
               when others =>
                  Version.Tar.Close (Writer);
                  Remove_Partial_Output (Work_Output);
                  raise;
            end;

         when Zip_Format =>
            declare
               Writer : Version.Zip.Zip_Writer;
            begin
               Version.Zip.Create (Writer, Work_Output);

               for Item of Emission loop
                  if Item.Kind = Emit_Directory then
                     Version.Zip.Add_Directory
                       (Writer, To_String (Item.Dir_Path));
                  else
                     declare
                        Current_Entry : constant Version.Objects.Tree_Entry :=
                          Selected_Entries.Element (Item.Entry_Ix);
                        Path         : constant String :=
                          To_String (Current_Entry.Path);
                        Archive_Path : constant String :=
                          With_Prefix (Archive_Prefix, Path);
                     begin
                        if Current_Entry.Kind = Version.Objects.Tree_Gitlink then
                              Version.Zip.Add_File
                                (Writer, Archive_Path, Gitlink_Content (Current_Entry.Id), False);
                        elsif Current_Entry.Kind = Version.Objects.Tree_Blob then
                              declare
                                 Obj : constant Version.Objects.Git_Object :=
                                   Version.Object_Cache.Read_Object (Repository, Object_Cache, Current_Entry.Id);
                              begin
                                 if Version.Objects.Kind (Obj) /= Version.Objects.Blob_Object then
                                    raise Ada.IO_Exceptions.Data_Error with
                                      "archive entry is not a blob: " & Path;
                                 end if;

                                 if Is_Symlink_Mode (To_String (Current_Entry.Mode)) then
                                    Version.Zip.Add_Symlink
                                      (Writer, Archive_Path, Version.Objects.Content (Obj));
                                 elsif Is_Regular_Mode (To_String (Current_Entry.Mode))
                                   or else Is_Executable_Mode (To_String (Current_Entry.Mode))
                                 then
                                    Version.Zip.Add_File
                                      (Writer,
                                       Archive_Path,
                                       Archive_Blob_Content
                                         (Repository, Subst, Path,
                                          Version.Objects.Content (Obj)),
                                       Is_Executable_Mode (To_String (Current_Entry.Mode)));
                                 else
                                    raise Ada.IO_Exceptions.Data_Error with
                                      "unsupported archive file mode "
                                      & To_String (Current_Entry.Mode) & ": " & Path;
                                 end if;
                              end;
                        end if;
                     end;
                  end if;
               end loop;

               Version.Zip.Close (Writer);
               Version.Files.Atomic_Replace (Work_Output, Output);
            exception
               when others =>
                  Version.Zip.Close (Writer);
                  Remove_Partial_Output (Work_Output);
                  raise;
            end;
      end case;
   end Create;

end Version.Archive;
