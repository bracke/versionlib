with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;   use Ada.Strings.Unbounded;
with Ada.IO_Exceptions;
with GNAT.OS_Lib;

with Version.Files;

package body Version.Verify is

   use type Version.Objects.Object_Kind;
   use type GNAT.OS_Lib.String_Access;

   LF : constant Character := Character'Val (10);
   Begin_Marker : constant String := "-----BEGIN PGP SIGNATURE-----";

   --  Split a signed object's raw content into the signed payload and the
   --  ASCII-armored signature. Handles both the tag layout (signature appended
   --  after the message) and the commit layout (a "gpgsig" header whose value
   --  spans continuation lines that begin with a space).
   procedure Split_Signature
     (Kind      : Version.Objects.Object_Kind;
      Content   : String;
      Payload   : out Unbounded_String;
      Signature : out Unbounded_String;
      Found     : out Boolean)
   is
   begin
      Payload := Null_Unbounded_String;
      Signature := Null_Unbounded_String;
      Found := False;

      if Kind = Version.Objects.Tag_Object then
         declare
            Pos : constant Natural :=
              Ada.Strings.Fixed.Index (Content, Begin_Marker);
         begin
            if Pos = 0 then
               return;
            end if;
            Payload := To_Unbounded_String (Content (Content'First .. Pos - 1));
            Signature := To_Unbounded_String (Content (Pos .. Content'Last));
            Found := True;
         end;
         return;
      end if;

      --  Commit: reconstruct the payload without the gpgsig header and rebuild
      --  the armored signature from the header's continuation lines.
      declare
         I         : Natural := Content'First;
         In_Header : Boolean := True;
      begin
         while I <= Content'Last loop
            declare
               Stop : Natural := I;
            begin
               while Stop <= Content'Last and then Content (Stop) /= LF loop
                  Stop := Stop + 1;
               end loop;
               declare
                  Line : constant String := Content (I .. Stop - 1);
               begin
                  if In_Header and then Line'Length = 0 then
                     In_Header := False;
                     Append (Payload, Line);
                     if Stop <= Content'Last then
                        Append (Payload, LF);
                     end if;
                  elsif In_Header and then Line'Length >= 7
                    and then Line (Line'First .. Line'First + 6) = "gpgsig "
                  then
                     Found := True;
                     Append
                       (Signature,
                        Line (Line'First + 7 .. Line'Last) & LF);
                     --  Consume continuation lines (leading space).
                     I := Stop + 1;
                     while I <= Content'Last loop
                        declare
                           CStop : Natural := I;
                        begin
                           while CStop <= Content'Last
                             and then Content (CStop) /= LF
                           loop
                              CStop := CStop + 1;
                           end loop;
                           exit when I > Content'Last
                             or else Content (I) /= ' ';
                           Append
                             (Signature,
                              Content (I + 1 .. CStop - 1) & LF);
                           I := CStop + 1;
                        end;
                     end loop;
                     goto Continue;
                  else
                     Append (Payload, Line);
                     if Stop <= Content'Last then
                        Append (Payload, LF);
                     end if;
                  end if;
               end;
               I := Stop + 1;
            end;
            <<Continue>>
         end loop;
      end;
   end Split_Signature;

   function Run_Gpg_Verify
     (Repo : Version.Repository.Repository_Handle;
      Payload, Signature : String) return Boolean
   is
      use Version.Files;
      Git_Dir  : constant String := Version.Repository.Git_Dir (Repo);
      Data_Path : constant String := Join (Git_Dir, "VERSION_VERIFY_DATA");
      Sig_Path  : constant String := Join (Git_Dir, "VERSION_VERIFY_SIG");
      Status    : Integer;
      Args      : GNAT.OS_Lib.Argument_List (1 .. 3);
   begin
      Delete_File_If_Exists (Data_Path);
      Delete_File_If_Exists (Sig_Path);
      Write_Binary_File_Atomic (Data_Path, Payload);
      Write_Binary_File_Atomic (Sig_Path, Signature);

      Args := [1 => new String'("--verify"),
               2 => new String'(Sig_Path),
               3 => new String'(Data_Path)];

      declare
         Program : GNAT.OS_Lib.String_Access :=
           GNAT.OS_Lib.Locate_Exec_On_Path ("gpg");
      begin
         if Program = null then
            for I in Args'Range loop
               GNAT.OS_Lib.Free (Args (I));
            end loop;
            Delete_File_If_Exists (Data_Path);
            Delete_File_If_Exists (Sig_Path);
            raise Ada.IO_Exceptions.Data_Error with "cannot verify: gpg not found";
         end if;
         Status := GNAT.OS_Lib.Spawn (Program.all, Args);
         GNAT.OS_Lib.Free (Program);
      end;

      for I in Args'Range loop
         GNAT.OS_Lib.Free (Args (I));
      end loop;
      Delete_File_If_Exists (Data_Path);
      Delete_File_If_Exists (Sig_Path);
      return Status = 0;
   end Run_Gpg_Verify;

   --  As Run_Gpg_Verify, but capture gpg's combined stdout+stderr into Output
   --  rather than letting it flow to the process stderr.
   function Run_Gpg_Verify_Capture
     (Repo : Version.Repository.Repository_Handle;
      Payload, Signature : String;
      Output : out Unbounded_String) return Boolean
   is
      use Version.Files;
      use type GNAT.OS_Lib.File_Descriptor;
      Git_Dir   : constant String := Version.Repository.Git_Dir (Repo);
      Data_Path : constant String := Join (Git_Dir, "VERSION_VERIFY_DATA");
      Sig_Path  : constant String := Join (Git_Dir, "VERSION_VERIFY_SIG");
      Out_Path  : constant String := Join (Git_Dir, "VERSION_VERIFY_OUT");
      Return_Code : Integer := 1;
      Args      : GNAT.OS_Lib.Argument_List (1 .. 3);
   begin
      Output := Null_Unbounded_String;
      Delete_File_If_Exists (Data_Path);
      Delete_File_If_Exists (Sig_Path);
      Delete_File_If_Exists (Out_Path);
      Write_Binary_File_Atomic (Data_Path, Payload);
      Write_Binary_File_Atomic (Sig_Path, Signature);

      Args := [1 => new String'("--verify"),
               2 => new String'(Sig_Path),
               3 => new String'(Data_Path)];

      declare
         Program : GNAT.OS_Lib.String_Access :=
           GNAT.OS_Lib.Locate_Exec_On_Path ("gpg");
      begin
         if Program = null then
            for I in Args'Range loop
               GNAT.OS_Lib.Free (Args (I));
            end loop;
            Delete_File_If_Exists (Data_Path);
            Delete_File_If_Exists (Sig_Path);
            raise Ada.IO_Exceptions.Data_Error with "cannot verify: gpg not found";
         end if;

         declare
            FD : constant GNAT.OS_Lib.File_Descriptor :=
              GNAT.OS_Lib.Create_File (Out_Path, GNAT.OS_Lib.Binary);
         begin
            if FD = GNAT.OS_Lib.Invalid_FD then
               Return_Code := GNAT.OS_Lib.Spawn (Program.all, Args);
            else
               GNAT.OS_Lib.Spawn
                 (Program_Name           => Program.all,
                  Args                   => Args,
                  Output_File_Descriptor => FD,
                  Return_Code            => Return_Code,
                  Err_To_Out             => True);
               GNAT.OS_Lib.Close (FD);
            end if;
         end;
         GNAT.OS_Lib.Free (Program);
      end;

      for I in Args'Range loop
         GNAT.OS_Lib.Free (Args (I));
      end loop;

      if Is_Ordinary_File (Out_Path) then
         Output := To_Unbounded_String (Read_Binary_File (Out_Path));
      end if;
      Delete_File_If_Exists (Data_Path);
      Delete_File_If_Exists (Sig_Path);
      Delete_File_If_Exists (Out_Path);
      return Return_Code = 0;
   end Run_Gpg_Verify_Capture;

   procedure Verify_Object_Reporting
     (Repo   : Version.Repository.Repository_Handle;
      Id     : Version.Objects.Hex_Object_Id;
      Result : out Verify_Result;
      Output : out Unbounded_String)
   is
      Obj  : constant Version.Objects.Git_Object :=
        Version.Objects.Read_Object (Repo, Id);
      Kind : constant Version.Objects.Object_Kind :=
        Version.Objects.Kind (Obj);
      Payload, Signature : Unbounded_String;
      Found : Boolean;
   begin
      Output := Null_Unbounded_String;
      Split_Signature
        (Kind      => Kind,
         Content   => Version.Objects.Content (Obj),
         Payload   => Payload,
         Signature => Signature,
         Found     => Found);

      if not Found then
         Result := No_Signature;
         return;
      end if;

      if Run_Gpg_Verify_Capture
           (Repo, To_String (Payload), To_String (Signature), Output)
      then
         Result := Good_Signature;
      else
         Result := Bad_Signature;
      end if;
   end Verify_Object_Reporting;

   --  Run gpg with a machine-readable status file, capturing the human text
   --  (stderr) into Human and the "[GNUPG:] ..." status lines into Status.
   procedure Run_Gpg_Status
     (Repo : Version.Repository.Repository_Handle;
      Payload, Signature : String;
      Human  : out Unbounded_String;
      Status : out Unbounded_String)
   is
      use Version.Files;
      Git_Dir     : constant String := Version.Repository.Git_Dir (Repo);
      Data_Path   : constant String := Join (Git_Dir, "VERSION_VERIFY_DATA");
      Sig_Path    : constant String := Join (Git_Dir, "VERSION_VERIFY_SIG");
      Out_Path    : constant String := Join (Git_Dir, "VERSION_VERIFY_OUT");
      Status_Path : constant String := Join (Git_Dir, "VERSION_VERIFY_STATUS");
      Return_Code : Integer := 1;
      Args        : GNAT.OS_Lib.Argument_List (1 .. 4);
   begin
      Human := Null_Unbounded_String;
      Status := Null_Unbounded_String;
      Delete_File_If_Exists (Data_Path);
      Delete_File_If_Exists (Sig_Path);
      Delete_File_If_Exists (Out_Path);
      Delete_File_If_Exists (Status_Path);
      Write_Binary_File_Atomic (Data_Path, Payload);
      Write_Binary_File_Atomic (Sig_Path, Signature);

      Args := [1 => new String'("--status-file=" & Status_Path),
               2 => new String'("--verify"),
               3 => new String'(Sig_Path),
               4 => new String'(Data_Path)];

      declare
         use type GNAT.OS_Lib.File_Descriptor;
         Program : GNAT.OS_Lib.String_Access :=
           GNAT.OS_Lib.Locate_Exec_On_Path ("gpg");
      begin
         if Program = null then
            for I in Args'Range loop
               GNAT.OS_Lib.Free (Args (I));
            end loop;
            Delete_File_If_Exists (Data_Path);
            Delete_File_If_Exists (Sig_Path);
            raise Ada.IO_Exceptions.Data_Error
              with "cannot verify: gpg not found";
         end if;
         declare
            FD : constant GNAT.OS_Lib.File_Descriptor :=
              GNAT.OS_Lib.Create_File (Out_Path, GNAT.OS_Lib.Binary);
         begin
            if FD = GNAT.OS_Lib.Invalid_FD then
               Return_Code := GNAT.OS_Lib.Spawn (Program.all, Args);
            else
               GNAT.OS_Lib.Spawn
                 (Program_Name           => Program.all,
                  Args                   => Args,
                  Output_File_Descriptor => FD,
                  Return_Code            => Return_Code,
                  Err_To_Out             => True);
               GNAT.OS_Lib.Close (FD);
            end if;
         end;
         GNAT.OS_Lib.Free (Program);
      end;

      for I in Args'Range loop
         GNAT.OS_Lib.Free (Args (I));
      end loop;

      if Is_Ordinary_File (Out_Path) then
         Human := To_Unbounded_String (Read_Binary_File (Out_Path));
      end if;
      if Is_Ordinary_File (Status_Path) then
         Status := To_Unbounded_String (Read_Binary_File (Status_Path));
      end if;
      Delete_File_If_Exists (Data_Path);
      Delete_File_If_Exists (Sig_Path);
      Delete_File_If_Exists (Out_Path);
      Delete_File_If_Exists (Status_Path);
   end Run_Gpg_Status;

   function Signature_Details
     (Repo : Version.Repository.Repository_Handle;
      Id   : Version.Objects.Hex_Object_Id)
      return Signature_Details_Result
   is
      LF   : constant Character := Character'Val (10);
      Obj  : constant Version.Objects.Git_Object :=
        Version.Objects.Read_Object (Repo, Id);
      Kind : constant Version.Objects.Object_Kind :=
        Version.Objects.Kind (Obj);
      Payload, Signature : Unbounded_String;
      Found  : Boolean;
      Human, Status : Unbounded_String;
      R      : Signature_Details_Result;

      --  Return token index N (1-based) of a space-separated line, or "".
      function Field (Line : String; N : Positive) return String is
         Count : Natural := 0;
         Start : Integer := Line'First;
      begin
         for I in Line'First .. Line'Last + 1 loop
            if I > Line'Last or else Line (I) = ' ' then
               if I > Start then
                  Count := Count + 1;
                  if Count = N then
                     return Line (Start .. I - 1);
                  end if;
               end if;
               Start := I + 1;
            end if;
         end loop;
         return "";
      end Field;

      --  The rest of the line starting at token N.
      function Rest (Line : String; N : Positive) return String is
         Count : Natural := 0;
         In_Tok : Boolean := False;
      begin
         for I in Line'Range loop
            if Line (I) /= ' ' then
               if not In_Tok then
                  Count := Count + 1;
                  In_Tok := True;
                  if Count = N then
                     return Line (I .. Line'Last);
                  end if;
               end if;
            else
               In_Tok := False;
            end if;
         end loop;
         return "";
      end Rest;
   begin
      R.Trust := To_Unbounded_String ("undefined");
      Split_Signature
        (Kind      => Kind,
         Content   => Version.Objects.Content (Obj),
         Payload   => Payload,
         Signature => Signature,
         Found     => Found);
      if not Found then
         return R;   --  unsigned: Present=False, Code='N', Trust="undefined"
      end if;
      R.Present := True;

      Run_Gpg_Status
        (Repo, To_String (Payload), To_String (Signature), Human, Status);
      R.Raw_Output := Human;

      --  Parse the "[GNUPG:] TOKEN ..." status lines.
      declare
         S       : constant String := To_String (Status);
         Line_S  : Integer := S'First;
         Prefix  : constant String := "[GNUPG:] ";
      begin
         for I in S'First .. S'Last + 1 loop
            if I > S'Last or else S (I) = LF then
               declare
                  Raw : constant String := S (Line_S .. I - 1);
               begin
                  if Raw'Length > Prefix'Length
                    and then Raw (Raw'First .. Raw'First + Prefix'Length - 1)
                             = Prefix
                  then
                     declare
                        Body_S : constant String :=
                          Raw (Raw'First + Prefix'Length .. Raw'Last);
                        Tok    : constant String := Field (Body_S, 1);
                     begin
                        if Tok = "GOODSIG" then
                           R.Code := 'G';
                           R.Key := To_Unbounded_String (Field (Body_S, 2));
                           R.Signer := To_Unbounded_String (Rest (Body_S, 3));
                        elsif Tok = "EXPSIG" then
                           R.Code := 'X';
                           R.Key := To_Unbounded_String (Field (Body_S, 2));
                           R.Signer := To_Unbounded_String (Rest (Body_S, 3));
                        elsif Tok = "EXPKEYSIG" then
                           R.Code := 'Y';
                           R.Key := To_Unbounded_String (Field (Body_S, 2));
                           R.Signer := To_Unbounded_String (Rest (Body_S, 3));
                        elsif Tok = "REVKEYSIG" then
                           R.Code := 'R';
                           R.Key := To_Unbounded_String (Field (Body_S, 2));
                           R.Signer := To_Unbounded_String (Rest (Body_S, 3));
                        elsif Tok = "BADSIG" then
                           R.Code := 'B';
                           R.Key := To_Unbounded_String (Field (Body_S, 2));
                           R.Signer := To_Unbounded_String (Rest (Body_S, 3));
                        elsif Tok = "ERRSIG" then
                           R.Code := 'E';
                           R.Key := To_Unbounded_String (Field (Body_S, 2));
                        elsif Tok = "VALIDSIG" then
                           R.Fingerprint :=
                             To_Unbounded_String (Field (Body_S, 2));
                           --  The last field is the primary-key fingerprint.
                           declare
                              N : Natural := 1;
                           begin
                              while Field (Body_S, N + 1) /= "" loop
                                 N := N + 1;
                              end loop;
                              R.Primary_FP :=
                                To_Unbounded_String (Field (Body_S, N));
                           end;
                        elsif Tok = "TRUST_UNDEFINED" then
                           R.Trust := To_Unbounded_String ("undefined");
                        elsif Tok = "TRUST_NEVER" then
                           R.Trust := To_Unbounded_String ("never");
                        elsif Tok = "TRUST_MARGINAL" then
                           R.Trust := To_Unbounded_String ("marginal");
                        elsif Tok = "TRUST_FULLY" then
                           R.Trust := To_Unbounded_String ("fully");
                        elsif Tok = "TRUST_ULTIMATE" then
                           R.Trust := To_Unbounded_String ("ultimate");
                        end if;
                     end;
                  end if;
               end;
               Line_S := I + 1;
            end if;
         end loop;
      end;

      --  git downgrades a good signature to 'U' when the key is not trusted.
      if R.Code = 'G'
        and then (To_String (R.Trust) = "undefined"
                  or else To_String (R.Trust) = "never")
      then
         R.Code := 'U';
      end if;
      return R;
   end Signature_Details;

   function Verify_Object
     (Repo : Version.Repository.Repository_Handle;
      Id   : Version.Objects.Hex_Object_Id)
      return Verify_Result
   is
      Obj  : constant Version.Objects.Git_Object :=
        Version.Objects.Read_Object (Repo, Id);
      Kind : constant Version.Objects.Object_Kind :=
        Version.Objects.Kind (Obj);
      Payload, Signature : Unbounded_String;
      Found : Boolean;
   begin
      Split_Signature
        (Kind      => Kind,
         Content   => Version.Objects.Content (Obj),
         Payload   => Payload,
         Signature => Signature,
         Found     => Found);

      if not Found then
         return No_Signature;
      end if;

      if Run_Gpg_Verify (Repo, To_String (Payload), To_String (Signature)) then
         return Good_Signature;
      else
         return Bad_Signature;
      end if;
   end Verify_Object;

end Version.Verify;
