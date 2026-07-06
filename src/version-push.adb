with Ada.Containers.Vectors;
with Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Strings.Unbounded;

with GNAT.OS_Lib;

with Version.Files;
with Version.Availability;
with Version.History;
with Version.Objects;
with Version.Push.Internal;
with Version.Receive_Pack;
with Version.Remotes;
with Version.Ref_Transaction;
with Version.Ref_Names;
with Version.Refs;
with Version.Revisions;
with Version.Config;
with Ada.Characters.Handling;
with Version.Repository;
with Version.Tags;
with Version.Transport;
with Version.Transport.Local;
with Version.Hooks;
with Version.Unsupported;

package body Version.Push is
   use Version.Objects;

   use Ada.Strings.Unbounded;
   use type Ada.Directories.File_Kind;

   Zero_Id : constant String := "0000000000000000000000000000000000000000";

   function Invalid_Remote_Branch_Commit_Id_Diagnostic return String is
   begin
      return "invalid remote branch commit id";
   end Invalid_Remote_Branch_Commit_Id_Diagnostic;

   function Invalid_Remote_Tag_Object_Id_Diagnostic return String is
   begin
      return "invalid remote tag object id";
   end Invalid_Remote_Tag_Object_Id_Diagnostic;

   function Remote_Branch_Changed_During_Push_Diagnostic return String is
   begin
      return "cannot push: remote branch changed during push";
   end Remote_Branch_Changed_During_Push_Diagnostic;

   function Remote_Tag_Changed_During_Push_Diagnostic return String is
   begin
      return "cannot push: remote tag changed during push";
   end Remote_Tag_Changed_During_Push_Diagnostic;

   type Tag_Update is record
      Name               : Unbounded_String;
      Object_Id          : Version.Objects.Object_Id_Storage;
      Expected_Remote_Id : Unbounded_String;
   end record;

   package Tag_Update_Vectors is new
     Ada.Containers.Vectors
       (Index_Type   => Natural,
        Element_Type => Tag_Update);

   procedure Run_Pre_Push_Hook
     (Repo        : Version.Repository.Repository_Handle;
      Remote_Name : String;
      Remote_Url  : String;
      Run_Hooks   : Boolean)
   is
      Args : Version.Hooks.Argument_Vectors.Vector;
   begin
      if Run_Hooks then
         Version.Hooks.Append_Argument (Args, Remote_Name);
         Version.Hooks.Append_Argument (Args, Remote_Url);
         Version.Hooks.Require_Hook_Success
           (Version.Hooks.Run_Hook
              (Repo      => Repo,
               Name      => "pre-push",
               Arguments => Args,
               Blocking  => True),
            "pre-push");
      end if;
   end Run_Pre_Push_Hook;

   function Remote_Url
     (Name : String)
      return String
   is
      Items : constant Version.Remotes.Remote_Vectors.Vector :=
        Version.Remotes.List_Remotes;
   begin
      Version.Ref_Names.Require_Remote_Name (Name);

      if not Items.Is_Empty then
         for I in Items.First_Index .. Items.Last_Index loop
            if To_String (Items.Element (I).Name) = Name then
               return To_String (Items.Element (I).Url);
            end if;
         end loop;
      end if;

      raise Ada.IO_Exceptions.Data_Error with
        Version.Availability.No_Remote_Configured (Name);
   end Remote_Url;

   function Remote_Git_Dir_For
     (Remote_Name : String)
      return String
   is
      Url : constant String :=
        Remote_Url (Remote_Name);
   begin
      Version.Ref_Names.Require_Remote_Name (Remote_Name);

      case Version.Transport.Detect_Transport (Url) is
         when Version.Transport.Local_Transport =>
            return
              Version.Transport.Local.Resolve_Git_Dir
                (Version.Transport.Strip_File_Scheme (Url));

         when Version.Transport.Http_Transport =>
            raise Ada.IO_Exceptions.Use_Error with
              "HTTP smart transport does not expose a local .git directory";

         when Version.Transport.Ssh_Transport =>
            raise Ada.IO_Exceptions.Use_Error with
              "SSH transport does not have a local .git directory";

         when Version.Transport.Unsupported_Transport =>
            raise Ada.IO_Exceptions.Data_Error with
              Version.Unsupported.Remote_Url;
      end case;
   end Remote_Git_Dir_For;

   function Local_Branch_Commit
     (Repo : Version.Repository.Repository_Handle;
      Name : String)
      return Version.Objects.Hex_Object_Id
   is
   begin
      Version.Ref_Names.Require_Branch_Name (Name);

      declare
         Path : constant String :=
           Version.Files.Join
             (Version.Repository.Common_Git_Dir (Repo),
              "refs/heads/" & Name);
      begin
         if not Ada.Directories.Exists (Path) then
            raise Ada.IO_Exceptions.Data_Error with
              "local branch does not exist: " & Name;
         end if;

         declare
            Text : constant String :=
              Version.Transport.Local.Read_First_Line (Path);
         begin
            if not Version.Objects.Is_Valid_Hex_Object_Id (Text) then
               raise Ada.IO_Exceptions.Data_Error with
                 "invalid local branch commit id";
            end if;

            return Version.Objects.To_Object_Id (Text);
         end;
      end;
   end Local_Branch_Commit;

   function Remote_Branch_Path
     (Remote_Git_Dir : String;
      Branch_Name    : String)
      return String
   is
   begin
      Version.Ref_Names.Require_Branch_Name (Branch_Name);

      return
        Version.Files.Join
          (Remote_Git_Dir,
           "refs/heads/" & Branch_Name);
   end Remote_Branch_Path;

   function Read_Remote_Ref_Object_Id
     (Path       : String;
      Diagnostic : String)
      return String
   is
   begin
      if GNAT.OS_Lib.Is_Symbolic_Link
           (Version.Files.To_Native_Path (Path))
        or else Ada.Directories.Kind (Path) = Ada.Directories.Special_File
      then
         raise Ada.IO_Exceptions.Data_Error with
           "invalid remote ref entry: " & Path;
      end if;

      declare
         Text : constant String := Version.Transport.Local.Read_First_Line (Path);
      begin
         if not Version.Objects.Is_Valid_Hex_Object_Id (Text) then
            raise Ada.IO_Exceptions.Data_Error with Diagnostic;
         end if;

         return Text;
      end;
   end Read_Remote_Ref_Object_Id;

   function Remote_Branch_Commit
     (Remote_Git_Dir : String;
      Branch_Name    : String)
      return String
   is
      Path : constant String :=
        Remote_Branch_Path (Remote_Git_Dir, Branch_Name);
   begin
      if not Ada.Directories.Exists (Path) then
         return "";
      end if;

      return Read_Remote_Ref_Object_Id
        (Path       => Path,
         Diagnostic => Invalid_Remote_Branch_Commit_Id_Diagnostic);
   end Remote_Branch_Commit;

   procedure Write_Remote_Branch
     (Remote_Git_Dir      : String;
      Branch_Name         : String;
      Commit_Id           : Version.Objects.Hex_Object_Id;
      Expected_Remote_Id  : String)
   is
      Tx : Version.Ref_Transaction.Transaction;
      Expected_Old : constant String :=
        (if Expected_Remote_Id'Length = 0 then Zero_Id else Expected_Remote_Id);
   begin
      Version.Push.Internal.Require_Remote_Branch_Unchanged
        (Remote_Git_Dir     => Remote_Git_Dir,
         Branch_Name        => Branch_Name,
         Expected_Remote_Id => Expected_Remote_Id);

      Version.Ref_Transaction.Start
        (Item => Tx,
         Repo => Version.Repository.Open_Git_Dir (Remote_Git_Dir));
      Version.Ref_Transaction.Add_Update
        (Item         => Tx,
         Ref_Name     => "refs/heads/" & Branch_Name,
         New_Id       => Commit_Id,
         Expected_Old => Expected_Old);
      Version.Ref_Transaction.Commit (Tx);
   exception
      when others =>
         Version.Ref_Transaction.Cancel (Tx);
         raise;
   end Write_Remote_Branch;

   procedure Push_Local_Branch
     (Remote_Name : String;
      Branch_Name : String;
      Force       : Boolean := False)
   is
      Local_Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;

      Remote_Git_Dir : constant String :=
        Remote_Git_Dir_For (Remote_Name);

      Local_Id : constant Version.Objects.Hex_Object_Id :=
        Local_Branch_Commit
          (Repo => Local_Repo,
           Name => Branch_Name);

      Remote_Id_Text : constant String :=
        Remote_Branch_Commit
          (Remote_Git_Dir => Remote_Git_Dir,
           Branch_Name    => Branch_Name);

      Copied_Targets : Version.Transport.Local.Copied_Object_Vectors.Vector;
   begin
      Version.Ref_Names.Require_Remote_Name (Remote_Name);
      Version.Ref_Names.Require_Branch_Name (Branch_Name);

      if Remote_Id_Text'Length > 0 then
         if not Version.Objects.Is_Valid_Hex_Object_Id (Remote_Id_Text) then
            raise Ada.IO_Exceptions.Data_Error with
              Invalid_Remote_Branch_Commit_Id_Diagnostic;
         end if;

         if not Force
           and then not Version.History.Is_Ancestor
                          (Repo       => Local_Repo,
                           Base_Id    =>
                             Version.Objects.To_Object_Id (Remote_Id_Text),
                           Derived_Id => Local_Id)
         then
            raise Ada.IO_Exceptions.Data_Error with
              "cannot push: remote branch is not an ancestor";
         end if;
      end if;

      Version.Transport.Local.Copy_Object_Store
        (Source_Git_Dir => Version.Repository.Git_Dir (Local_Repo),
         Target_Git_Dir => Remote_Git_Dir,
         Copied_Targets => Copied_Targets);

      begin
         Write_Remote_Branch
           (Remote_Git_Dir     => Remote_Git_Dir,
            Branch_Name        => Branch_Name,
            Commit_Id          => Local_Id,
            Expected_Remote_Id => Remote_Id_Text);
      exception
         when others =>
            Version.Transport.Local.Rollback_Copied_Objects (Copied_Targets);
            raise;
      end;
   end Push_Local_Branch;

   procedure Push
     (Remote_Name : String;
      Branch_Name : String;
      Run_Hooks   : Boolean := True;
      Force       : Boolean := False)
   is
      Url : constant String := Remote_Url (Remote_Name);
      Local_Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
   begin
      Version.Ref_Names.Require_Remote_Name (Remote_Name);
      Version.Ref_Names.Require_Branch_Name (Branch_Name);

      Run_Pre_Push_Hook
        (Repo        => Local_Repo,
         Remote_Name => Remote_Name,
         Remote_Url  => Url,
         Run_Hooks   => Run_Hooks);

      case Version.Transport.Detect_Transport (Url) is
         when Version.Transport.Local_Transport =>
            Push_Local_Branch
              (Remote_Name => Remote_Name,
               Branch_Name => Branch_Name,
               Force       => Force);

         when Version.Transport.Http_Transport =>
            Version.Receive_Pack.Push_Branch
              (Repo        => Local_Repo,
               Remote_Name => Remote_Name,
               Url         => Url,
               Branch_Name => Branch_Name,
               Force       => Force);

         when Version.Transport.Ssh_Transport =>
            Version.Receive_Pack.Push_Branch_Ssh
              (Repo        => Local_Repo,
               Remote_Name => Remote_Name,
               Url         => Url,
               Branch_Name => Branch_Name,
               Force       => Force);

         when Version.Transport.Unsupported_Transport =>
            raise Ada.IO_Exceptions.Data_Error with
              Version.Unsupported.Remote_Url;
      end case;
   end Push;

   function Remote_Tag_Path
     (Remote_Git_Dir : String;
      Tag_Name       : String)
      return String
   is
   begin
      Version.Ref_Names.Require_Tag_Name (Tag_Name);

      return
        Version.Files.Join
          (Remote_Git_Dir,
           "refs/tags/" & Tag_Name);
   end Remote_Tag_Path;

   function Remote_Tag_Object_Id
     (Remote_Git_Dir : String;
      Tag_Name       : String) return String
   is
      Path : constant String :=
        Remote_Tag_Path
          (Remote_Git_Dir => Remote_Git_Dir,
           Tag_Name       => Tag_Name);
   begin
      if not Ada.Directories.Exists (Path) then
         return "";
      end if;

      return Read_Remote_Ref_Object_Id
        (Path       => Path,
         Diagnostic => Invalid_Remote_Tag_Object_Id_Diagnostic);
   end Remote_Tag_Object_Id;

   function Validate_Remote_Tag_Update
     (Remote_Git_Dir : String;
      Tag_Name       : String;
      Object_Id      : Version.Objects.Hex_Object_Id;
      Force          : Boolean := False) return String
   is
      Existing : constant String :=
        Remote_Tag_Object_Id
          (Remote_Git_Dir => Remote_Git_Dir,
           Tag_Name       => Tag_Name);
   begin
      if not Force
        and then Existing'Length > 0
        and then Existing /= To_String (Object_Id)
      then
         raise Ada.IO_Exceptions.Data_Error with
           "cannot overwrite existing tag: " & Tag_Name;
      end if;

      return Existing;
   end Validate_Remote_Tag_Update;

   procedure Write_Remote_Tags
     (Remote_Git_Dir : String;
      Updates        : Tag_Update_Vectors.Vector;
      Force          : Boolean := False)
   is
      Tx : Version.Ref_Transaction.Transaction;
      Has_Updates : Boolean := False;
   begin
      if Updates.Is_Empty then
         return;
      end if;

      for I in Updates.First_Index .. Updates.Last_Index loop
         declare
            Update : constant Tag_Update := Updates.Element (I);
         begin
            Version.Push.Internal.Require_Remote_Tag_Unchanged
              (Remote_Git_Dir     => Remote_Git_Dir,
               Tag_Name           => To_String (Update.Name),
               Expected_Remote_Id => To_String (Update.Expected_Remote_Id));
         end;
      end loop;

      Version.Ref_Transaction.Start
        (Item => Tx,
         Repo => Version.Repository.Open_Git_Dir (Remote_Git_Dir));

      for I in Updates.First_Index .. Updates.Last_Index loop
         declare
            Update             : constant Tag_Update := Updates.Element (I);
            Expected_Remote_Id : constant String :=
              To_String (Update.Expected_Remote_Id);
         begin
            if Expected_Remote_Id'Length = 0 then
               Version.Ref_Transaction.Add_Update
                 (Item         => Tx,
                  Ref_Name     => "refs/tags/" & To_String (Update.Name),
                  New_Id       => Update.Object_Id,
                  Expected_Old => Zero_Id);
               Has_Updates := True;
            elsif Force then
               Version.Ref_Transaction.Add_Update
                 (Item         => Tx,
                  Ref_Name     => "refs/tags/" & To_String (Update.Name),
                  New_Id       => Update.Object_Id,
                  Expected_Old => Expected_Remote_Id);
               Has_Updates := True;
            end if;
         end;
      end loop;

      if Has_Updates then
         Version.Ref_Transaction.Commit (Tx);
      else
         Version.Ref_Transaction.Cancel (Tx);
      end if;
   exception
      when others =>
         Version.Ref_Transaction.Cancel (Tx);
         raise;
   end Write_Remote_Tags;

   procedure Push_Tags
     (Remote_Name : String;
      Run_Hooks   : Boolean := True;
      Force       : Boolean := False)
   is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;

      Url : constant String := Remote_Url (Remote_Name);

      Tags : constant Version.Tags.Tag_Name_Vectors.Vector :=
        Version.Tags.List_Tags;

      Updates : Tag_Update_Vectors.Vector;
   begin
      Version.Ref_Names.Require_Remote_Name (Remote_Name);

      Run_Pre_Push_Hook
        (Repo        => Repo,
         Remote_Name => Remote_Name,
         Remote_Url  => Url,
         Run_Hooks   => Run_Hooks);

      case Version.Transport.Detect_Transport (Url) is
         when Version.Transport.Local_Transport =>
            declare
               Remote_Git_Dir : constant String :=
                 Remote_Git_Dir_For (Remote_Name);
            begin
               if not Tags.Is_Empty then
                  for I in Tags.First_Index .. Tags.Last_Index loop
                     declare
                        Tag_Name : constant String :=
                          Ada.Strings.Unbounded.To_String
                            (Tags.Element (I));

                        Object_Id : constant Version.Objects.Hex_Object_Id :=
                          Version.Tags.Resolve_Tag (Tag_Name);
                     begin
                        Version.Ref_Names.Require_Tag_Name (Tag_Name);

                        declare
                           Expected_Remote_Id : constant String :=
                             Validate_Remote_Tag_Update
                               (Remote_Git_Dir => Remote_Git_Dir,
                                Tag_Name       => Tag_Name,
                                Object_Id      => Object_Id,
                                Force          => Force);
                        begin
                           Updates.Append
                             (Tag_Update'
                                (Name               => To_Unbounded_String (Tag_Name),
                                 Object_Id          => Object_Id,
                                 Expected_Remote_Id =>
                                   To_Unbounded_String (Expected_Remote_Id)));
                        end;
                     end;
                  end loop;
               end if;

               declare
                  Copied_Targets :
                    Version.Transport.Local.Copied_Object_Vectors.Vector;
               begin
                  Version.Transport.Local.Copy_Object_Store
                    (Source_Git_Dir => Version.Repository.Common_Git_Dir (Repo),
                     Target_Git_Dir => Remote_Git_Dir,
                     Copied_Targets => Copied_Targets);

                  begin
                     Write_Remote_Tags
                       (Remote_Git_Dir => Remote_Git_Dir,
                        Updates        => Updates,
                        Force          => Force);
                  exception
                     when others =>
                        Version.Transport.Local.Rollback_Copied_Objects
                          (Copied_Targets);
                        raise;
                  end;
               end;
            end;

         when Version.Transport.Http_Transport =>
            for I in Tags.First_Index .. Tags.Last_Index loop
               declare
                  Tag_Name : constant String :=
                    Ada.Strings.Unbounded.To_String (Tags.Element (I));
               begin
                  Version.Ref_Names.Require_Tag_Name (Tag_Name);
                  Version.Receive_Pack.Push_Tag
                    (Repo        => Repo,
                     Remote_Name => Remote_Name,
                     Url         => Url,
                     Tag_Name    => Tag_Name,
                     Object_Id   => Version.Tags.Resolve_Tag (Tag_Name),
                     Force       => Force);
               end;
            end loop;

         when Version.Transport.Ssh_Transport =>
            for I in Tags.First_Index .. Tags.Last_Index loop
               declare
                  Tag_Name : constant String :=
                    Ada.Strings.Unbounded.To_String (Tags.Element (I));
               begin
                  Version.Ref_Names.Require_Tag_Name (Tag_Name);
                  Version.Receive_Pack.Push_Tag_Ssh
                    (Repo        => Repo,
                     Remote_Name => Remote_Name,
                     Url         => Url,
                     Tag_Name    => Tag_Name,
                     Object_Id   => Version.Tags.Resolve_Tag (Tag_Name),
                     Force       => Force);
               end;
            end loop;

         when Version.Transport.Unsupported_Transport =>
            raise Ada.IO_Exceptions.Data_Error with
              Version.Unsupported.Remote_Url;
      end case;
   end Push_Tags;

   procedure Delete_Ref
     (Remote_Name : String;
      Ref_Name    : String;
      Run_Hooks   : Boolean := True)
   is
      Url : constant String := Remote_Url (Remote_Name);
      Local_Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
   begin
      Version.Ref_Names.Require_Remote_Name (Remote_Name);
      Version.Ref_Names.Require_Ref_Name (Ref_Name);

      Run_Pre_Push_Hook
        (Repo        => Local_Repo,
         Remote_Name => Remote_Name,
         Remote_Url  => Url,
         Run_Hooks   => Run_Hooks);

      case Version.Transport.Detect_Transport (Url) is
         when Version.Transport.Local_Transport =>
            declare
               Remote_Git_Dir : constant String :=
                 Remote_Git_Dir_For (Remote_Name);
               Remote_Repo : constant Version.Repository.Repository_Handle :=
                 Version.Repository.Open_Git_Dir (Remote_Git_Dir);
               Tx : Version.Ref_Transaction.Transaction;
            begin
               if not Version.Refs.Ref_Exists (Remote_Repo, Ref_Name) then
                  raise Ada.IO_Exceptions.Data_Error
                    with "remote ref does not exist: " & Ref_Name;
               end if;

               Version.Ref_Transaction.Start (Tx, Remote_Repo);
               Version.Ref_Transaction.Add_Delete
                 (Item         => Tx,
                  Ref_Name     => Ref_Name,
                  Expected_Old =>
                    To_String (Version.Refs.Resolve_Ref (Remote_Repo, Ref_Name)));
               Version.Ref_Transaction.Commit (Tx);
            end;

         when Version.Transport.Http_Transport =>
            Version.Receive_Pack.Delete_Ref
              (Repo        => Local_Repo,
               Remote_Name => Remote_Name,
               Url         => Url,
               Ref_Name    => Ref_Name);

         when Version.Transport.Ssh_Transport =>
            Version.Receive_Pack.Delete_Ref_Ssh
              (Repo        => Local_Repo,
               Remote_Name => Remote_Name,
               Url         => Url,
               Ref_Name    => Ref_Name);

         when Version.Transport.Unsupported_Transport =>
            raise Ada.IO_Exceptions.Data_Error with
              Version.Unsupported.Remote_Url;
      end case;
   end Delete_Ref;

   procedure Push_Refspec
     (Remote_Name : String;
      Source      : String;
      Dest_Ref    : String;
      Force       : Boolean := False;
      Run_Hooks   : Boolean := True)
   is
      Url : constant String := Remote_Url (Remote_Name);
      Local_Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
      New_Id : constant Version.Objects.Hex_Object_Id :=
        Version.Revisions.Resolve_Commit (Local_Repo, Source);
   begin
      Version.Ref_Names.Require_Remote_Name (Remote_Name);
      Version.Ref_Names.Require_Ref_Name (Dest_Ref);

      Run_Pre_Push_Hook
        (Repo        => Local_Repo,
         Remote_Name => Remote_Name,
         Remote_Url  => Url,
         Run_Hooks   => Run_Hooks);

      case Version.Transport.Detect_Transport (Url) is
         when Version.Transport.Local_Transport =>
            declare
               Remote_Git_Dir : constant String :=
                 Remote_Git_Dir_For (Remote_Name);
               Remote_Repo : constant Version.Repository.Repository_Handle :=
                 Version.Repository.Open_Git_Dir (Remote_Git_Dir);
               Old_Id : constant String :=
                 (if Version.Refs.Ref_Exists (Remote_Repo, Dest_Ref)
                  then To_String (Version.Refs.Resolve_Ref (Remote_Repo, Dest_Ref))
                  else "");
               Copied_Targets :
                 Version.Transport.Local.Copied_Object_Vectors.Vector;
            begin
               if Old_Id'Length > 0 and then not Force then
                  if not Version.History.Is_Ancestor
                           (Repo       => Local_Repo,
                            Base_Id    => Version.Objects.To_Object_Id (Old_Id),
                            Derived_Id => New_Id)
                  then
                     raise Ada.IO_Exceptions.Data_Error with
                       "cannot push: non-fast-forward update to " & Dest_Ref;
                  end if;
               end if;

               Version.Transport.Local.Copy_Object_Store
                 (Source_Git_Dir =>
                    Version.Repository.Common_Git_Dir (Local_Repo),
                  Target_Git_Dir => Remote_Git_Dir,
                  Copied_Targets => Copied_Targets);

               begin
                  declare
                     Tx : Version.Ref_Transaction.Transaction;
                  begin
                     Version.Ref_Transaction.Start (Tx, Remote_Repo);
                     Version.Ref_Transaction.Add_Update
                       (Item         => Tx,
                        Ref_Name     => Dest_Ref,
                        New_Id       => New_Id,
                        Expected_Old => Old_Id);
                     Version.Ref_Transaction.Commit (Tx);
                  end;
               exception
                  when others =>
                     Version.Transport.Local.Rollback_Copied_Objects
                       (Copied_Targets);
                     raise;
               end;
            end;

         when Version.Transport.Http_Transport =>
            Version.Receive_Pack.Push_Ref
              (Repo        => Local_Repo,
               Remote_Name => Remote_Name,
               Url         => Url,
               Ref_Name    => Dest_Ref,
               New_Id      => New_Id,
               Force       => Force);

         when Version.Transport.Ssh_Transport =>
            Version.Receive_Pack.Push_Ref_Ssh
              (Repo        => Local_Repo,
               Remote_Name => Remote_Name,
               Url         => Url,
               Ref_Name    => Dest_Ref,
               New_Id      => New_Id,
               Force       => Force);

         when Version.Transport.Unsupported_Transport =>
            raise Ada.IO_Exceptions.Data_Error with
              Version.Unsupported.Remote_Url;
      end case;
   end Push_Refspec;

   procedure Push_Default
     (Remote_Name : String;
      Run_Hooks   : Boolean := True)
   is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
      Entries : constant Version.Config.Config_Entry_Vectors.Vector :=
        Version.Config.Read_All (Repo);
      Key : constant String :=
        Ada.Characters.Handling.To_Lower ("remote." & Remote_Name & ".push");
      Found : Boolean := False;

      function Normalize_Ref (R : String) return String is
        (if R'Length >= 5 and then R (R'First .. R'First + 4) = "refs/"
         then R else "refs/heads/" & R);

      --  Apply one configured refspec, matching the command-line forms:
      --  "+src:dst" forces, ":dst" deletes, "src:dst" pushes, "branch" pushes.
      procedure Apply (Spec : String) is
         Force : Boolean := False;
         First : Positive := Spec'First;
         Colon : Natural := 0;
      begin
         if Spec'Length > 0 and then Spec (Spec'First) = '+' then
            Force := True;
            First := Spec'First + 1;
         end if;

         for J in First .. Spec'Last loop
            if Spec (J) = ':' then
               Colon := J;
               exit;
            end if;
         end loop;

         if Colon = 0 then
            Push
              (Remote_Name => Remote_Name,
               Branch_Name => Spec (First .. Spec'Last),
               Run_Hooks   => Run_Hooks,
               Force       => Force);
         else
            declare
               Src : constant String := Spec (First .. Colon - 1);
               Dst : constant String := Spec (Colon + 1 .. Spec'Last);
            begin
               if Dst'Length = 0 then
                  raise Ada.IO_Exceptions.Data_Error
                    with "push refspec is missing a destination ref: " & Spec;
               end if;

               if Src'Length = 0 then
                  Delete_Ref
                    (Remote_Name => Remote_Name,
                     Ref_Name    => Normalize_Ref (Dst),
                     Run_Hooks   => Run_Hooks);
               else
                  Push_Refspec
                    (Remote_Name => Remote_Name,
                     Source      => Src,
                     Dest_Ref    => Normalize_Ref (Dst),
                     Force       => Force,
                     Run_Hooks   => Run_Hooks);
               end if;
            end;
         end if;
      end Apply;
   begin
      Version.Ref_Names.Require_Remote_Name (Remote_Name);

      for I in Entries.First_Index .. Entries.Last_Index loop
         if Ada.Characters.Handling.To_Lower
              (Version.Config.Config_Entry_Name (Entries.Element (I))) = Key
         then
            Found := True;
            Apply (To_String (Entries.Element (I).Value));
         end if;
      end loop;

      if not Found then
         raise Ada.IO_Exceptions.Data_Error with
           "no refspec given and remote." & Remote_Name
           & ".push is not configured";
      end if;
   end Push_Default;

end Version.Push;
