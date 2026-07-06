with Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Streams; use Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Version.Branch;
with Version.Fetch;
with Version.Config;
with Version.Files;
with Version.Init;
with Version.Objects;
with Version.Refs;
with Version.Remotes;
with Version.Hash;
with Version.Repository;
with Version.Reflog;
with Version.Ref_Names;
with Version.Restore;
with Version.Staging;
with Version.Transport;
with Version.Transport.Local;
with Version.Transport.Http;
with Version.Transport.Ssh;
with Version.Tracking;
with Version.Upload_Pack;
with Version.Shallow;
with Version.Unsupported;

package body Version.Clone is

   use Ada.Strings.Unbounded;

   procedure Write_HEAD
     (Repo : Version.Repository.Repository_Handle; Name : String) is
   begin
      Version.Ref_Names.Require_Branch_Name (Name);

      Version.Files.Write_Binary_File_Atomic
        (Path    =>
           Version.Files.Join
             (Version.Repository.Common_Git_Dir (Repo), "HEAD"),
         Content => "ref: refs/heads/" & Name & Character'Val (10));
   end Write_HEAD;

   procedure Write_Index_For_Head (Repo : Version.Repository.Repository_Handle)
   is
      Commit : constant String := Version.Refs.Current_Commit_Id (Repo);

      Commit_Obj : Version.Objects.Git_Object;
   begin
      if not Version.Objects.Is_Valid_Hex_Object_Id (Commit) then
         raise Ada.IO_Exceptions.Data_Error
           with "HEAD does not point to a valid commit";
      end if;

      Commit_Obj :=
        Version.Objects.Read_Object
          (Repo, Version.Objects.To_Object_Id (Commit));

      declare
         Tree_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.Commit_Tree_Id (Commit_Obj);
      begin
         Version.Staging.Write_From_Tree (Repo => Repo, Tree_Id => Tree_Id);
      end;
   end Write_Index_For_Head;

   function Remote_Tracking_Ref_Path
     (Repo   : Version.Repository.Repository_Handle;
      Remote : String;
      Branch : String) return String is
   begin
      Version.Ref_Names.Require_Remote_Name (Remote);
      Version.Ref_Names.Require_Branch_Name (Branch);

      return
        Version.Files.Join
          (Version.Repository.Common_Git_Dir (Repo),
           "refs/remotes/" & Remote & "/" & Branch);
   end Remote_Tracking_Ref_Path;

   type Collecting_Consumer is limited new Version.Transport.Http.Byte_Consumer
   with record
      Data : Unbounded_String;
   end record;

   overriding
   procedure Consume
     (Item : in out Collecting_Consumer;
      Data : Ada.Streams.Stream_Element_Array) is
   begin
      for I in Data'Range loop
         Append (Item.Data, Character'Val (Data (I)));
      end loop;
   end Consume;

   function To_Stream (Text : String) return Ada.Streams.Stream_Element_Array
   is
      Result :
        Ada.Streams.Stream_Element_Array
          (1 .. Ada.Streams.Stream_Element_Offset (Text'Length));
      J      : Ada.Streams.Stream_Element_Offset := Result'First;
   begin
      for I in Text'Range loop
         Result (J) := Ada.Streams.Stream_Element (Character'Pos (Text (I)));
         J := J + 1;
      end loop;

      return Result;
   end To_Stream;

   function Http_Default_Branch (Source : String) return String is
      Discovery_Raw : Collecting_Consumer;
   begin
      Version.Transport.Http.Discover_Upload_Pack
        (Url => Source, Consumer => Discovery_Raw);

      declare
         Discovery : constant Version.Upload_Pack.Discovery_Result :=
           Version.Upload_Pack.Parse_Discovery
             (To_Stream (To_String (Discovery_Raw.Data)));
      begin
         return
           Version.Upload_Pack.Default_Branch_From_Advertisements
             (Discovery.Refs);
      end;
   end Http_Default_Branch;

   function Ssh_Default_Branch (Source : String) return String is
      Stream : Version.Transport.Ssh.Ssh_Stream;
      Raw_Advertisement : Unbounded_String;
      Buffer : Ada.Streams.Stream_Element_Array (1 .. 8192);
      Last   : Ada.Streams.Stream_Element_Offset;
   begin
      Version.Transport.Ssh.Open_Upload_Pack (Source, Stream);

      loop
         Version.Transport.Ssh.Read_Some
           (Stream => Stream, Buffer => Buffer, Last => Last);

         exit when Last < Buffer'First;

         for I in Buffer'First .. Last loop
            Append (Raw_Advertisement, Character'Val (Buffer (I)));
         end loop;

         exit when Ada.Strings.Fixed.Index
           (To_String (Raw_Advertisement), "0000") /= 0;
      end loop;

      if Length (Raw_Advertisement) > 0 then
         Version.Transport.Ssh.Write (Stream, To_Stream ("0000"));
      end if;

      begin
         Version.Transport.Ssh.Close (Stream);
      exception
         when Ada.IO_Exceptions.Use_Error =>
            if Length (Raw_Advertisement) = 0 then
               raise;
            end if;
      end;

      declare
         Discovery : constant Version.Upload_Pack.Discovery_Result :=
           Version.Upload_Pack.Parse_Advertisement
             (To_Stream (To_String (Raw_Advertisement)));
      begin
         return
           Version.Upload_Pack.Default_Branch_From_Advertisements
             (Discovery.Refs);
      end;
   exception
      when others =>
         Version.Transport.Ssh.Close (Stream);
         raise;
   end Ssh_Default_Branch;

   function Source_Git_Dir_For (Source : String) return String is
   begin
      case Version.Transport.Detect_Transport (Source) is
         when Version.Transport.Local_Transport       =>
            return
              Version.Transport.Local.Resolve_Git_Dir
                (Version.Transport.Strip_File_Scheme (Source));

         when Version.Transport.Http_Transport        =>
            raise Ada.IO_Exceptions.Use_Error
              with
                "HTTP smart transport does not expose a local .git directory";

         when Version.Transport.Ssh_Transport         =>
            raise Ada.IO_Exceptions.Use_Error
              with "SSH transport does not have a local .git directory";

         when Version.Transport.Unsupported_Transport =>
            raise Ada.IO_Exceptions.Data_Error
              with Version.Unsupported.Remote_Url;
      end case;
   end Source_Git_Dir_For;

   function Remote_Default_Branch (Remote_Git_Dir : String) return String is
      Head_Path : constant String :=
        Version.Files.Join (Remote_Git_Dir, "HEAD");

      Prefix : constant String := "ref: refs/heads/";
   begin
      if not Ada.Directories.Exists (Head_Path) then
         return "";
      end if;

      declare
         Head_Text : constant String :=
           Version.Transport.Local.Read_First_Line (Head_Path);
      begin
         if Head_Text'Length <= Prefix'Length then
            return "";
         end if;

         if Head_Text (Head_Text'First .. Head_Text'First + Prefix'Length - 1)
           /= Prefix
         then
            return "";
         end if;

         declare
            Branch : constant String :=
              Head_Text (Head_Text'First + Prefix'Length .. Head_Text'Last);
         begin
            if Version.Ref_Names.Is_Valid_Branch_Name (Branch) then
               return Branch;
            end if;

            raise Ada.IO_Exceptions.Data_Error
              with "invalid remote default branch name: " & Branch;
         end;
      end;
   end Remote_Default_Branch;

   procedure Checkout_Fetched_Branch
     (Repo : Version.Repository.Repository_Handle; Branch : String)
   is
      Ref_Path : constant String :=
        Remote_Tracking_Ref_Path
          (Repo => Repo, Remote => "origin", Branch => Branch);

      Zero_Id : constant String := "0000000000000000000000000000000000000000";

      Commit_Id : constant String :=
        Version.Transport.Local.Read_First_Line (Ref_Path);

      Branch_Ref : constant String := "refs/heads/" & Branch;
   begin
      Version.Ref_Names.Require_Branch_Name (Branch);

      Version.Restore.Preflight_Working_Tree_For_Commit
        (Repo => Repo, Commit_Id => Version.Objects.To_Object_Id (Commit_Id));

      Version.Branch.Create_Branch (Name => Branch, Commit_Id => Commit_Id);

      Write_HEAD (Repo, Branch);

      Version.Reflog.Append
        (Repo    => Repo,
         Ref     => "HEAD",
         Old_Id  => Zero_Id,
         New_Id  => Commit_Id,
         Message => "clone: checkout " & Branch);

      Version.Reflog.Append
        (Repo    => Repo,
         Ref     => Branch_Ref,
         Old_Id  => Zero_Id,
         New_Id  => Commit_Id,
         Message => "clone: checkout " & Branch);

      begin
         Version.Tracking.Set_Upstream
           (Repo        => Repo,
            Branch_Name => Branch,
            Remote_Name => "origin",
            Merge_Ref   => "refs/heads/" & Branch);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            null;
      end;

      Version.Restore.Restore_Working_Tree (Repo);
      Write_Index_For_Head (Repo);
   end Checkout_Fetched_Branch;

   procedure Clone_Internal
     (Source : String; Target : String; Has_Depth : Boolean; Depth : Positive;
      Filter : String := "")
   is
      Fetch_Source : Unbounded_String;
      Stored_Source : Unbounded_String;
      --  The clone target must be created with the same object format as the
      --  source; for a local source we read it from the source config. (Remote
      --  smart-transport sources are assumed sha1 until object-format is
      --  negotiated from the ref advertisement.)
      Object_Format : Version.Hash.Hash_Algorithm := Version.Hash.Sha1;

      function Normalized_Local_Source (Url : String) return String is
         Local_Path : constant String := Version.Transport.Strip_File_Scheme (Url);
      begin
         return Ada.Directories.Full_Name
           (Version.Files.To_Native_Path (Local_Path));
      end Normalized_Local_Source;

      procedure Populate_Target is
         Remote_Source : constant String := To_String (Fetch_Source);
      begin
         Version.Remotes.Add_Remote (Name => "origin", Url => To_String (Stored_Source));

         if To_String (Stored_Source) /= Remote_Source then
            Version.Remotes.Set_Url ("origin", Remote_Source);
         end if;

         if Filter'Length > 0 then
            Version.Fetch.Fetch ("origin", Filter_Spec => Filter);
         elsif Has_Depth then
            Version.Fetch.Fetch ("origin", Depth);
         else
            Version.Fetch.Fetch ("origin");
         end if;

         if To_String (Stored_Source) /= Remote_Source then
            Version.Remotes.Set_Url ("origin", To_String (Stored_Source));
         end if;

         --  Mark the repository as a partial clone so that omitted objects are
         --  lazily fetched from origin (the promisor) on first access.
         if Filter'Length > 0 then
            declare
               Repo : constant Version.Repository.Repository_Handle :=
                 Version.Repository.Open;
            begin
               Version.Config.Set_Key
                 (Repo, "core.repositoryformatversion", "1");
               Version.Config.Set_Key (Repo, "extensions.partialClone", "origin");
               Version.Config.Set_Key (Repo, "remote.origin.promisor", "true");
               Version.Config.Set_Key
                 (Repo, "remote.origin.partialclonefilter", Filter);
            end;
         end if;

         declare
            Repo : constant Version.Repository.Repository_Handle :=
              Version.Repository.Open;

            Default_Branch : constant String :=
              (case Version.Transport.Detect_Transport (Remote_Source) is
                 when Version.Transport.Local_Transport       =>
                   Remote_Default_Branch (Source_Git_Dir_For (Remote_Source)),
                 when Version.Transport.Http_Transport        =>
                   Http_Default_Branch (Remote_Source),
                 when Version.Transport.Ssh_Transport         =>
                   Ssh_Default_Branch (Remote_Source),
                 when Version.Transport.Unsupported_Transport =>
                   raise Ada.IO_Exceptions.Data_Error
                     with "unsupported clone source URL");

            Main_Ref : constant String :=
              Remote_Tracking_Ref_Path
                (Repo => Repo, Remote => "origin", Branch => "main");

            Master_Ref : constant String :=
              Remote_Tracking_Ref_Path
                (Repo => Repo, Remote => "origin", Branch => "master");
         begin
            if Default_Branch'Length > 0 then
               if Version.Files.Is_Ordinary_File
                    (Remote_Tracking_Ref_Path
                       (Repo   => Repo,
                        Remote => "origin",
                        Branch => Default_Branch))
               then
                  Checkout_Fetched_Branch
                    (Repo => Repo, Branch => Default_Branch);
               else
                  raise Ada.IO_Exceptions.Data_Error
                    with
                      "missing remote-tracking ref for default branch: "
                      & Default_Branch;
               end if;

            elsif Version.Files.Is_Ordinary_File (Main_Ref) then
               Checkout_Fetched_Branch (Repo => Repo, Branch => "main");

            elsif Version.Files.Is_Ordinary_File (Master_Ref) then
               Checkout_Fetched_Branch (Repo => Repo, Branch => "master");

            else
               raise Ada.IO_Exceptions.Data_Error
                 with
                   "remote has no default branch, origin/main, or origin/master";
            end if;
         end;
      end Populate_Target;
   begin
      if Source'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error
           with "clone source must not be empty";
      end if;

      if Target'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error
           with "clone target must not be empty";
      end if;

      if Ada.Directories.Exists (Version.Files.To_Native_Path (Target)) then
         raise Ada.IO_Exceptions.Data_Error
           with "clone target already exists: " & Target;
      end if;

      --  Validate and freeze the source before creating or entering the target.
      case Version.Transport.Detect_Transport (Source) is
         when Version.Transport.Local_Transport       =>
            if Has_Depth then
               raise Ada.IO_Exceptions.Data_Error
                 with "shallow clone is only supported for smart transports";
            end if;

            declare
               Remote_Git_Dir : constant String := Source_Git_Dir_For (Source);
               Normalized    : constant String := Normalized_Local_Source (Source);
               pragma Unreferenced (Remote_Git_Dir);
            begin
               Fetch_Source := To_Unbounded_String (Normalized);
               Stored_Source :=
                 (if Version.Transport.Strip_File_Scheme (Source) = Source
                  then To_Unbounded_String (Normalized)
                  else To_Unbounded_String (Source));
            end;

         when Version.Transport.Http_Transport        =>
            Fetch_Source := To_Unbounded_String (Source);
            Stored_Source := To_Unbounded_String (Source);

         when Version.Transport.Ssh_Transport         =>
            declare
               Remote : constant Version.Transport.Ssh.Ssh_Remote :=
                 Version.Transport.Ssh.Parse (Source);
               pragma Unreferenced (Remote);
            begin
               Fetch_Source := To_Unbounded_String (Source);
               Stored_Source := To_Unbounded_String (Source);
            end;

         when Version.Transport.Unsupported_Transport =>
            raise Ada.IO_Exceptions.Data_Error
              with "unsupported clone source URL";
      end case;

      --  Create the target with the remote's object format (read from a local
      --  source config, or negotiated from the HTTP/SSH ref advertisement).
      Object_Format := Version.Fetch.Remote_Object_Format (Source);

      Version.Init.Init (Target, Object_Format);

      begin
         Version.Files.With_Directory
           (Path => Target, Action => Populate_Target'Access);
      exception
         when others =>
            begin
               Version.Files.Delete_Directory_Tree_If_Exists (Target);
            exception
               when others =>
                  null;
            end;

            raise;
      end;
   end Clone_Internal;

   procedure Clone (Source : String; Target : String) is
   begin
      Clone_Internal (Source, Target, False, 1);
   end Clone;

   procedure Clone (Source : String; Target : String; Depth : Positive) is
   begin
      Version.Shallow.Validate_Depth (Depth);
      Clone_Internal (Source, Target, True, Depth);
   end Clone;

   procedure Clone_Filtered
     (Source : String; Target : String; Filter : String) is
   begin
      Clone_Internal (Source, Target, False, 1, Filter => Filter);
   end Clone_Filtered;

end Version.Clone;
