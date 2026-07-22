with Ada.IO_Exceptions;
with Ada.Strings.Unbounded;
with Ada.Strings.Fixed;

with Version.Log;
with Version.Objects; use Version.Objects;
with Version.Revisions;
with Version.Ref_Format;

package body Version.Show is

   use Ada.Strings.Unbounded;

   LF : constant Character := Character'Val (10);

   function Resolve_Revision
     (Repo : Version.Repository.Repository_Handle;
      Name : String)
      return Version.Objects.Hex_Object_Id
   is
   begin
      return Version.Revisions.Resolve_Commit (Repo, Name);
   end Resolve_Revision;

   function Show_Commit
     (Repo         : Version.Repository.Repository_Handle;
      Commit_Id    : Version.Objects.Hex_Object_Id;
      Options      : Version.Diff.Diff_Options := (others => <>);
      No_Patch     : Boolean := False;
      Oneline      : Boolean := False;
      Format       : String := "";
      Format_Oneline : Boolean := False)
      return String
   is
      Obj      : constant Version.Objects.Git_Object :=
        Version.Objects.Read_Object (Repo, Commit_Id);
      Parent   : constant String := Version.Objects.Commit_Parent_Id (Obj);
      Result   : Unbounded_String;
   begin
      if Version.Objects.Kind (Obj) /= Version.Objects.Commit_Object then
         raise Ada.IO_Exceptions.Data_Error with "object is not a commit: " & To_String (Commit_Id);
      end if;

      if Oneline then
         --  Max_Count 1: show reports this commit, not the history behind it.
         Append
           (Result,
            Version.Log.Log_Oneline_From_Commit
              (Repo, Commit_Id, Max_Count => 1));
      elsif Format'Length > 0 then
         Append
           (Result,
            Version.Log.Log_Formatted_From_Commit
              (Repo, Commit_Id, Format, Max_Count => 1));
         --  git's oneline pretty format runs straight into the diff; other
         --  formats get a blank line separating them from it.
         if not Format_Oneline then
            Append (Result, Character'Val (10));
         end if;
      else
         Append
           (Result,
            Version.Log.Format_Commit (Repo, Commit_Id, Full_Message => True));
         --  The blank line here separates the header from the diff that
         --  follows. With -s there is no diff, so git ends at the message.
         if not No_Patch then
            Append (Result, Character'Val (10));
         end if;
      end if;

      if No_Patch then
         return To_String (Result);
      end if;

      --  git shows no patch for a merge unless asked with -m/-c/--cc: with
      --  more than one parent there is no single "the" diff, and picking the
      --  first parent silently presents one side's changes as the commit's.
      --  A --stat is still produced, and matches git's combined stat.
      if Natural (Version.Objects.Commit_Parent_Ids (Obj).Length) > 1
        and then not Options.Stat
      then
         return To_String (Result);
      end if;

      if Parent'Length = 0 then
         Append
           (Result, Version.Diff.Diff_Root_Commit (Repo, Commit_Id, Options));
      else
         Append
           (Result,
            Version.Diff.Diff_Commits
              (Repo    => Repo,
               Old_Id  => Version.Objects.To_Object_Id (Parent),
               New_Id  => Commit_Id,
               Options => Options));
      end if;

      return To_String (Result);
   end Show_Commit;

   function Show_Object
     (Repo         : Version.Repository.Repository_Handle;
      Spec         : String;
      Options      : Version.Diff.Diff_Options := (others => <>);
      No_Patch     : Boolean := False;
      Oneline      : Boolean := False;
      Format       : String := "";
      Format_Oneline : Boolean := False)
      return String
   is
      Raw : constant Version.Objects.Hex_Object_Id :=
        Version.Revisions.Resolve (Repo, Spec);
      Obj : constant Version.Objects.Git_Object :=
        Version.Objects.Read_Object (Repo, Raw);

      --  The value of a header line ("tag v2", "tagger X <y> 1 +0000"), or "".
      function Header (Text, Key : String) return String is
         P : Natural := Text'First;
      begin
         while P <= Text'Last loop
            declare
               E : Natural := P;
            begin
               while E <= Text'Last and then Text (E) /= LF loop
                  E := E + 1;
               end loop;
               exit when P = E;   --  blank line ends the header block
               declare
                  Line : constant String := Text (P .. E - 1);
               begin
                  if Line'Length >= Key'Length
                    and then Line (Line'First .. Line'First + Key'Length - 1)
                             = Key
                  then
                     return Line (Line'First + Key'Length .. Line'Last);
                  end if;
               end;
               P := E + 1;
            end;
         end loop;
         return "";
      end Header;
   begin
      case Version.Objects.Kind (Obj) is
         when Version.Objects.Commit_Object =>
            return Show_Commit
              (Repo, Raw, Options, No_Patch, Oneline, Format, Format_Oneline);

         when Version.Objects.Tag_Object =>
            declare
               Content : constant String := Version.Objects.Content (Obj);
               Name    : constant String := Header (Content, "tag ");
               Tagger  : constant String := Header (Content, "tagger ");
               Gt      : constant Natural :=
                 Ada.Strings.Fixed.Index (Tagger, ">");
               Ident   : constant String :=
                 (if Gt = 0 then Tagger else Tagger (Tagger'First .. Gt));
               Ts      : constant String :=
                 (if Gt = 0 or else Gt + 2 > Tagger'Last then ""
                  else Tagger (Gt + 2 .. Tagger'Last));
               Blank   : constant Natural :=
                 Ada.Strings.Fixed.Index (Content, LF & LF);
               Message : constant String :=
                 (if Blank = 0 then "" else Content (Blank + 2 .. Content'Last));
               Result  : Unbounded_String;
            begin
               Append (Result, "tag " & Name & LF);
               Append (Result, "Tagger: " & Ident & LF);
               Append
                 (Result,
                  "Date:   " & Version.Ref_Format.Git_Date (Ts) & LF & LF);
               Append (Result, Message);
               if Message'Length = 0
                 or else Message (Message'Last) /= LF
               then
                  Append (Result, LF);
               end if;
               Append (Result, LF);   --  blank line before the tagged object
               --  git recurses into whatever the tag points at.
               Append
                 (Result,
                  Show_Object
                    (Repo,
                     Version.Objects.To_String
                       (Version.Objects.Tag_Target_Id (Obj)),
                     Options, No_Patch, Oneline, Format, Format_Oneline));
               return To_String (Result);
            end;

         when Version.Objects.Tree_Object =>
            declare
               Result : Unbounded_String;
            begin
               Append (Result, "tree " & Spec & LF & LF);
               for E of Version.Objects.Tree_Entries (Repo, Raw) loop
                  Append
                    (Result,
                     To_String (E.Path)
                     & (if E.Kind = Version.Objects.Tree_Directory
                        then "/" else "")
                     & LF);
               end loop;
               return To_String (Result);
            end;

         when others =>
            return Version.Objects.Content (Obj);   --  a blob, verbatim
      end case;
   end Show_Object;

end Version.Show;
