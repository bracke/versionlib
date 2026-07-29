with Ada.IO_Exceptions;
with Ada.Strings.Unbounded;
with Ada.Strings.Fixed;

with Version.Log;
with Version.Objects; use Version.Objects;
with Version.Revisions;
with Version.Ref_Format;

package body Version.Show is

   use Ada.Strings.Unbounded;
   use type Version.Log.Pretty_Kind;

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
      Format_Oneline : Boolean := False;
      Date_Mode    : String := "";
      First_Parent : Boolean := False;
      Combined_M   : Boolean := False;
      Kind         : Version.Log.Pretty_Kind := Version.Log.Pretty_Medium;
      Show_Notes   : Boolean := True)
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

      --  git's -m shows a merge once per parent: each header carries
      --  "(from <parent>)" and is followed by the diff against that parent.
      if Combined_M
        and then Natural (Version.Objects.Commit_Parent_Ids (Obj).Length) > 1
      then
         declare
            Parents  : constant Version.Objects.Object_Id_Vectors.Vector :=
              Version.Objects.Commit_Parent_Ids (Obj);
            Full     : constant String := To_String (Commit_Id);
            C_Ab     : constant Natural :=
              Version.Revisions.Unique_Abbrev_Length (Repo, Commit_Id, 7);
            Subject  : constant String :=
              Version.Objects.Commit_Message_First_Line (Obj);
            Out_Text : Unbounded_String;
            First    : Boolean := True;
         begin
            for P of Parents loop
               declare
                  P_Hex : constant String := Version.Objects.To_String (P);
                  P_Ab  : constant Natural :=
                    Version.Revisions.Unique_Abbrev_Length (Repo, P, 7);
                  --  Oneline abbreviates the parent id; the medium header
                  --  spells it in full, as git does.
                  From  : constant String :=
                    (if Oneline
                     then "(from "
                          & P_Hex (P_Hex'First .. P_Hex'First + P_Ab - 1) & ")"
                     else "(from " & P_Hex & ")");
               begin
                  --  git blank-separates the per-parent medium blocks; the
                  --  oneline ones run straight on.
                  if not First and then not Oneline then
                     Append (Out_Text, "" & LF);
                  end if;
                  First := False;
                  if Oneline then
                     Append
                       (Out_Text,
                        Full (Full'First .. Full'First + C_Ab - 1) & " "
                        & From & " " & Subject & LF);
                  else
                     --  Splice "(from P)" onto the commit line of the medium
                     --  header, then a blank line before the diff.
                     declare
                        Hdr : constant String :=
                          Version.Log.Format_Commit
                            (Repo, Commit_Id, Full_Message => True,
                             Kind => Kind, Show_Notes => Show_Notes,
                             Date_Mode => Date_Mode);
                        NL  : constant Natural :=
                          Ada.Strings.Fixed.Index (Hdr, "" & LF);
                     begin
                        if NL = 0 then
                           Append (Out_Text, Hdr & " " & From & LF);
                        else
                           Append
                             (Out_Text,
                              Hdr (Hdr'First .. NL - 1) & " " & From
                              & Hdr (NL .. Hdr'Last) & LF);
                        end if;
                     end;
                  end if;
                  if not No_Patch then
                     Append
                       (Out_Text,
                        Version.Diff.Diff_Commits
                          (Repo    => Repo,
                           Old_Id  => Version.Objects.To_Object_Id (P_Hex),
                           New_Id  => Commit_Id,
                           Options => Options));
                  end if;
               end;
            end loop;
            return To_String (Out_Text);
         end;
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
              (Repo, Commit_Id, Format, Max_Count => 1,
               Date_Mode => Date_Mode));
         --  Other formats get a blank line separating them from the diff --
         --  but only when there is a diff (not under -s) and not for the
         --  oneline pretty form, which runs straight in.
         if not Format_Oneline and then not No_Patch then
            Append (Result, Character'Val (10));
         end if;
      else
         Append
           (Result,
            Version.Log.Format_Commit
              (Repo, Commit_Id, Full_Message => True,
               Kind => Kind, Show_Notes => Show_Notes,
               Date_Mode => Date_Mode));
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
      --  --first-parent picks the first parent's diff for a merge, so it is
      --  no longer skipped.
      if Natural (Version.Objects.Commit_Parent_Ids (Obj).Length) > 1
        and then not Options.Stat
        and then not First_Parent
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
      Format_Oneline : Boolean := False;
      Date_Mode    : String := "";
      First_Parent : Boolean := False;
      Combined_M   : Boolean := False;
      Kind         : Version.Log.Pretty_Kind := Version.Log.Pretty_Medium;
      Show_Notes   : Boolean := True)
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
              (Repo, Raw, Options, No_Patch, Oneline, Format, Format_Oneline,
               Date_Mode, First_Parent, Combined_M, Kind, Show_Notes);

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
               --  The tagger line mirrors the commit header per format: medium
               --  shows "Tagger:" then a "Date:" line, fuller aligns to 12 and
               --  labels the date "TaggerDate:", and short/full/raw show the
               --  tagger alone.
               if Kind = Version.Log.Pretty_Fuller then
                  Append (Result, "Tagger:     " & Ident & LF);
                  Append
                    (Result,
                     "TaggerDate: " & Version.Ref_Format.Git_Date (Ts) & LF);
               elsif Kind = Version.Log.Pretty_Medium then
                  Append (Result, "Tagger: " & Ident & LF);
                  Append
                    (Result, "Date:   " & Version.Ref_Format.Git_Date (Ts) & LF);
               else
                  Append (Result, "Tagger: " & Ident & LF);
               end if;
               Append (Result, LF);
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
                     Options, No_Patch, Oneline, Format, Format_Oneline,
                     Date_Mode, First_Parent, Combined_M, Kind, Show_Notes));
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
