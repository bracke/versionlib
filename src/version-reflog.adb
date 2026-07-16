with Ada.Calendar;
with Ada.Directories;
with Ada.IO_Exceptions;
with Version.Config;
with Version.Files;
with Version.Hash;
with Version.Objects;
with Version.Ref_Names;
with Version.Reftable;
with Version.Reftable.Writer;

package body Version.Reflog is

   use Ada.Strings.Unbounded;

   function Now_Seconds return Long_Long_Integer is
      Epoch : constant Ada.Calendar.Time :=
        Ada.Calendar.Time_Of (Year => 1970, Month => 1, Day => 1);
   begin
      return Long_Long_Integer
        (Ada.Calendar."-" (Ada.Calendar.Clock, Epoch));
   end Now_Seconds;

   function Path
     (Repo : Version.Repository.Repository_Handle;
      Ref  : String)
      return String
   is
   begin
      if Ref /= "HEAD" then
         Version.Ref_Names.Require_Ref_Name (Ref);
      end if;

      if Ref = "HEAD" then
         return
           Version.Files.Join
             (Version.Repository.Git_Dir (Repo),
              "logs/HEAD");
      end if;

      return
        Version.Files.Join
          (Version.Repository.Common_Git_Dir (Repo),
           "logs/" & Ref);
   end Path;

   function Read_Entries
     (Repo : Version.Repository.Repository_Handle;
      Ref  : String := "HEAD")
      return Log_Entry_Vectors.Vector
   is
      HT : constant Character := Character'Val (9);
      LF : constant Character := Character'Val (10);

      Reflog_File : constant String := Path (Repo, Ref);
      Result      : Log_Entry_Vectors.Vector;

      procedure Parse_Line (Line : String) is
         Sp1 : Natural := 0;
         Sp2 : Natural := 0;
         Tab : Natural := 0;
      begin
         for K in Line'Range loop
            if Line (K) = HT then
               Tab := K;
               exit;
            elsif Line (K) = ' ' then
               if Sp1 = 0 then
                  Sp1 := K;
               elsif Sp2 = 0 then
                  Sp2 := K;
               end if;
            end if;
         end loop;

         --  A well-formed line is "OLD NEW <ident> <time>\t<message>"; skip
         --  anything that does not carry both ids and a tab-delimited message.
         if Sp1 = 0 or else Sp2 = 0 or else Tab = 0 then
            return;
         end if;

         Result.Append
           (Log_Entry'
              (Old_Id  => To_Unbounded_String (Line (Line'First .. Sp1 - 1)),
               New_Id  => To_Unbounded_String (Line (Sp1 + 1 .. Sp2 - 1)),
               Message => To_Unbounded_String (Line (Tab + 1 .. Line'Last))));
      end Parse_Line;
   begin
      if Version.Reftable.Is_Reftable (Repo) then
         --  Reftable stores the reflog newest-first; Read_Entries yields
         --  oldest-first (so the last element is @{0}).
         declare
            Logs : constant Version.Reftable.Log_Record_Vectors.Vector :=
              Version.Reftable.Log_For (Repo, Ref);
         begin
            for I in reverse Logs.First_Index .. Logs.Last_Index loop
               declare
                  L : constant Version.Reftable.Log_Record :=
                    Logs.Element (I);
               begin
                  Result.Append
                    (Log_Entry'
                       (Old_Id  => To_Unbounded_String
                          (Version.Objects.To_String (L.Old_Id)),
                        New_Id  => To_Unbounded_String
                          (Version.Objects.To_String (L.New_Id)),
                        Message => L.Message));
               end;
            end loop;
            return Result;
         end;
      end if;

      if not Version.Files.Is_Ordinary_File (Reflog_File) then
         return Result;
      end if;

      declare
         Content : constant String :=
           Version.Files.Read_Binary_File (Reflog_File);
         Start   : Positive := Content'First;
      begin
         for I in Content'Range loop
            if Content (I) = LF then
               if I > Start then
                  Parse_Line (Content (Start .. I - 1));
               end if;
               Start := I + 1;
            end if;
         end loop;

         --  Tolerate a final line without a trailing LF.
         if Start <= Content'Last then
            Parse_Line (Content (Start .. Content'Last));
         end if;
      end;

      return Result;
   end Read_Entries;

   procedure Preflight_Append
     (Repo       : Version.Repository.Repository_Handle;
      Ref        : String;
      Error_Kind : Lock_Error_Kind := Data_Error_On_Lock)
   is
      Lock_Path : constant String := Path (Repo, Ref) & ".lock";
   begin
      if Ada.Directories.Exists (Version.Files.To_Native_Path (Lock_Path)) then
         case Error_Kind is
            when Data_Error_On_Lock =>
               raise Ada.IO_Exceptions.Data_Error
                 with "lock file already exists: " & Lock_Path;
            when Use_Error_On_Lock =>
               raise Ada.IO_Exceptions.Use_Error
                 with "cannot append reflog: lock exists: " & Lock_Path;
         end case;
      end if;
   end Preflight_Append;

   --  A reflog entry is stamped with the committer's time: what
   --  GIT_COMMITTER_DATE says, or now in the local timezone.
   function Time_Stamp
      return String
   is (Version.Config.Committer_Timestamp);

   procedure Append
     (Repo    : Version.Repository.Repository_Handle;
      Ref     : String;
      Old_Id  : String;
      New_Id  : String;
      Message : String)
   is
      Reflog_File : constant String :=
        Path (Repo, Ref);
      Lock_Path : constant String := Reflog_File & ".lock";

      Identity : constant Version.Config.Identity :=
        Version.Config.User_Identity (Repo);

      --  A null object id must match the repository's hash width; callers may
      --  pass the 40-zero sha1 null (Zero_Object_Id) even in a sha256 repo, so
      --  widen an all-zero id to the repo's width here.
      Width : constant Natural :=
        Version.Hash.Hex_Length (Version.Repository.Algorithm (Repo));

      function Normalized (Id : String) return String is
        (if Id'Length /= Width and then (for all C of Id => C = '0')
         then [1 .. Width => '0']
         else Id);

      Norm_Old : constant String := Normalized (Old_Id);
      Norm_New : constant String := Normalized (New_Id);

      New_Line : constant String :=
        Norm_Old
        & " "
        & Norm_New
        & " "
        & Version.Config.Trim
            (Ada.Strings.Unbounded.To_String (Identity.Name))
        & " <"
        & Version.Config.Trim
            (Ada.Strings.Unbounded.To_String (Identity.Email))
        & "> "
        & Time_Stamp
        & Character'Val (9)
        & Message
        & Character'Val (10);
   begin
      if not Version.Objects.Is_Valid_Hex_Object_Id (Norm_Old) then
         raise Ada.IO_Exceptions.Data_Error with "invalid reflog old id";
      end if;

      if not Version.Objects.Is_Valid_Hex_Object_Id (Norm_New) then
         raise Ada.IO_Exceptions.Data_Error with "invalid reflog new id";
      end if;

      if Version.Reftable.Is_Reftable (Repo) then
         --  Append the entry as a log record in a new table; Append_Table
         --  assigns the next update index (so it sorts newest-first) and runs
         --  compaction. Existing refs and reflog stay in the older tables.
         declare
            Logs : Version.Reftable.Log_Record_Vectors.Vector;
            Rec  : Version.Reftable.Log_Record;
         begin
            Rec.Ref_Name        := To_Unbounded_String (Ref);
            Rec.Old_Id          := Version.Objects.To_Object_Id (Norm_Old);
            Rec.New_Id          := Version.Objects.To_Object_Id (Norm_New);
            Rec.Committer_Name  := Identity.Name;
            Rec.Committer_Email := Identity.Email;
            Rec.Time_Seconds    := Now_Seconds;
            Rec.TZ_Offset       := 0;
            Rec.Message         := To_Unbounded_String (Message);
            Logs.Append (Rec);
            Version.Reftable.Writer.Append_Table
              (Repo,
               Version.Reftable.Ref_Record_Vectors.Empty_Vector,
               Version.Reftable.Ref_Record_Vectors.Empty_Vector,
               Logs);
            return;
         end;
      end if;

      if Ada.Directories.Exists (Version.Files.To_Native_Path (Lock_Path)) then
         raise Ada.IO_Exceptions.Data_Error
           with "lock file already exists: " & Lock_Path;
      end if;

      Version.Files.Create_Parent_Directories (Reflog_File);

      declare
         Existing : constant String :=
           (if Version.Files.Is_Ordinary_File (Reflog_File)
            then Version.Files.Read_Binary_File (Reflog_File)
            else "");
      begin
         Version.Files.Write_Binary_File
           (Path    => Lock_Path,
            Content => Existing & New_Line);
         Version.Files.Atomic_Replace (Lock_Path, Reflog_File);
      exception
         when others =>
            Version.Files.Delete_File_If_Exists (Lock_Path);
            raise;
      end;
   end Append;

end Version.Reflog;