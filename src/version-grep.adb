with Ada.IO_Exceptions;

with Regexp;

with Version.Files;
with Version.Staging;

package body Version.Grep is

   use Ada.Strings.Unbounded;

   LF : constant Character := Character'Val (10);

   --  Translate a POSIX basic regular expression (git grep's default) into the
   --  extended syntax the Regexp engine accepts: in a BRE the operators
   --  ( ) { } + ? | are literal unless backslash-escaped -- the reverse of an
   --  ERE -- so swap their escaped/unescaped meaning. Characters inside a
   --  bracket expression are copied verbatim.
   function BRE_To_ERE (Pattern : String) return String is
      Result   : Unbounded_String;
      In_Class : Boolean := False;
      I        : Natural := Pattern'First;
   begin
      while I <= Pattern'Last loop
         declare
            C : constant Character := Pattern (I);
         begin
            if In_Class then
               Append (Result, C);
               if C = ']' then
                  In_Class := False;
               end if;
               I := I + 1;
            elsif C = '[' then
               Append (Result, C);
               In_Class := True;
               I := I + 1;
            elsif C = '\' and then I < Pattern'Last then
               declare
                  N : constant Character := Pattern (I + 1);
               begin
                  case N is
                     when '(' | ')' | '{' | '}' | '+' | '?' | '|' =>
                        Append (Result, N);        --  BRE special -> ERE special
                     when others =>
                        Append (Result, '\');      --  keep escape (\. \* \\ \1)
                        Append (Result, N);
                  end case;
                  I := I + 2;
               end;
            elsif C in '(' | ')' | '{' | '}' | '+' | '?' | '|' then
               Append (Result, '\');               --  BRE literal -> ERE literal
               Append (Result, C);
               I := I + 1;
            else
               Append (Result, C);
               I := I + 1;
            end if;
         end;
      end loop;
      return To_String (Result);
   end BRE_To_ERE;

   function Compile_Pattern
     (Pattern : String; Kind : Pattern_Kind) return Regexp.Regexp
   is
      use type Regexp.Compile_Status;
      Result : constant Regexp.Compile_Result :=
        (case Kind is
            when Fixed_String  => Regexp.Compile_Literal (Pattern),
            when Basic_Regex   => Regexp.Compile (BRE_To_ERE (Pattern)),
            when Extended_Regex | Perl_Regex => Regexp.Compile (Pattern));
   begin
      if Result.Status /= Regexp.Compile_Ok then
         raise Ada.IO_Exceptions.Data_Error
           with "invalid grep pattern: " & Pattern;
      end if;
      return Result.Expression;
   end Compile_Pattern;

   function Search
     (Repo      : Version.Repository.Repository_Handle;
      Pattern   : String;
      Opts      : Options := (others => <>);
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector :=
        Version.Pathspec.Pathspec_Vectors.Empty_Vector)
      return Match_Vectors.Vector
   is
      use type Regexp.Match_Status;
      Entries : constant Version.Staging.Index_Entry_Vectors.Vector :=
        Version.Staging.Load (Repo);
      Root    : constant String := Version.Repository.Root_Path (Repo);
      Result  : Match_Vectors.Vector;
      Expr    : constant Regexp.Regexp := Compile_Pattern (Pattern, Opts.Kind);
      M_Opts  : constant Regexp.Match_Options :=
        (Case_Sensitive => not Opts.Ignore_Case,
         Whole_Word     => Opts.Word_Match,
         others         => <>);

      function Hit (Line : String) return Boolean is
         Found   : constant Regexp.Match_Result :=
           Regexp.Find_First (Expr, Line, M_Opts);
         Matched : constant Boolean := Found.Status = Regexp.Match_Ok;
      begin
         return Matched xor Opts.Invert;
      end Hit;
   begin
      for E of Entries loop
         if E.Stage = 0 then
            declare
               Path : constant String := To_String (E.Path);
            begin
               if Pathspecs.Is_Empty
                 or else Version.Pathspec.Matches_Any (Pathspecs, Path)
               then
                  declare
                     Full : constant String := Version.Files.Join (Root, Path);
                  begin
                     if Version.Files.Is_Ordinary_File (Full) then
                        declare
                           Content : constant String :=
                             Version.Files.Read_Binary_File (Full);
                           Start   : Positive := Content'First;
                           Line_No : Positive := 1;

                           --  git's buffer_is_binary: a NUL in the first 8000
                           --  bytes marks the file binary.
                           Is_Bin  : constant Boolean :=
                             (for some K in Content'First ..
                                Integer'Min (Content'Last, Content'First + 7999)
                              => Content (K) = Character'Val (0));

                           procedure Emit (Line : String) is
                           begin
                              if Hit (Line) then
                                 Result.Append
                                   (Match'
                                      (Path    => To_Unbounded_String (Path),
                                       Line_No => Line_No,
                                       Text    => To_Unbounded_String (Line),
                                       Binary  => Is_Bin));
                              end if;
                              Line_No := Line_No + 1;
                           end Emit;
                        begin
                           for I in Content'Range loop
                              if Content (I) = LF then
                                 Emit (Content (Start .. I - 1));
                                 Start := I + 1;
                              end if;
                           end loop;
                           if Start <= Content'Last then
                              Emit (Content (Start .. Content'Last));
                           end if;
                        end;
                     end if;
                  end;
               end if;
            end;
         end if;
      end loop;
      return Result;
   end Search;

   function Search
     (Repo        : Version.Repository.Repository_Handle;
      Pattern     : String;
      Ignore_Case : Boolean)
      return Match_Vectors.Vector is
   begin
      return Search
        (Repo, Pattern,
         Opts => (Kind => Basic_Regex, Ignore_Case => Ignore_Case,
                  others => <>));
   end Search;

end Version.Grep;
