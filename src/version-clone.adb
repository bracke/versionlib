with Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Streams; use Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Version.Branch;
with Version.Bundle;
with Version.Fetch;
with Ada.Text_IO;

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

   --  Record the remote's default branch as a symbolic ref
   --  refs/remotes/<Remote>/HEAD -> refs/remotes/<Remote>/<Branch>, as
   --  `git clone` does. Lets `fetch`/`pull` order their summary the way git
   --  does (default branch first) and `<remote>` resolve to the default.
   procedure Write_Remote_HEAD
     (Repo   : Version.Repository.Repository_Handle;
      Remote : String;
      Branch : String) is
   begin
      Version.Ref_Names.Require_Branch_Name (Branch);

      Version.Files.Write_Binary_File_Atomic
        (Path    =>
           Version.Files.Join
             (Version.Repository.Common_Git_Dir (Repo),
              "refs/remotes/" & Remote & "/HEAD"),
         Content =>
           "ref: refs/remotes/" & Remote & "/" & Branch & Character'Val (10));
   end Write_Remote_HEAD;

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
      Write_Remote_HEAD (Repo, "origin", Branch);

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

   --  git parity for a dangling remote HEAD: the remote's HEAD names a branch
   --  that was not fetched (e.g. a bare repo whose default branch was never
   --  pushed). Like `git clone`, point HEAD at that (unborn) branch and record
   --  its upstream config, but create no branch ref, write no origin/HEAD, and
   --  check nothing out; warn instead of failing.
   procedure Set_Unborn_Default_Branch
     (Repo : Version.Repository.Repository_Handle; Branch : String) is
   begin
      Version.Ref_Names.Require_Branch_Name (Branch);

      Write_HEAD (Repo, Branch);
      Version.Config.Set_Key (Repo, "branch." & Branch & ".remote", "origin");
      Version.Config.Set_Key
        (Repo, "branch." & Branch & ".merge", "refs/heads/" & Branch);

      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         "warning: remote HEAD refers to nonexistent ref, unable to checkout");
   end Set_Unborn_Default_Branch;

   --  Clone from a git bundle file: unpack its packfile, register the bundle
   --  as `origin`, materialize the bundle's refs as remote-tracking refs (and
   --  tags), then check out the default branch. Matches `git clone <bundle>`.
   procedure Clone_From_Bundle (Bundle_Path : String; Target : String) is
      Full_Bundle : constant String :=
        Ada.Directories.Full_Name
          (Version.Files.To_Native_Path (Bundle_Path));
      Header      : constant Version.Bundle.Bundle_Info :=
        Version.Bundle.Read_Header (Full_Bundle);
      Object_Format : Version.Hash.Hash_Algorithm := Version.Hash.Sha1;

      Heads_Prefix : constant String := "refs/heads/";
      Tags_Prefix  : constant String := "refs/tags/";

      function Has_Prefix (S, P : String) return Boolean is
        (S'Length >= P'Length
         and then S (S'First .. S'First + P'Length - 1) = P);

      procedure Populate is
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Info : Version.Bundle.Bundle_Info;
         Head_Id        : Unbounded_String;
         Default_Branch : Unbounded_String;

         --  The bundle id recorded for refs/heads/Name, or "" if absent.
         function Branch_Id (Name : String) return String is
         begin
            for R of Info.Refs loop
               if To_String (R.Name) = Heads_Prefix & Name then
                  return Version.Objects.To_String (R.Id);
               end if;
            end loop;
            return "";
         end Branch_Id;

         function Matches_Head (Name : String) return Boolean is
           (Branch_Id (Name)'Length > 0
            and then (Length (Head_Id) = 0
                      or else Branch_Id (Name) = To_String (Head_Id)));
      begin
         Version.Remotes.Add_Remote (Name => "origin", Url => Full_Bundle);
         Version.Bundle.Unbundle (Repo, Full_Bundle, Info);

         --  Bundle refs become remote-tracking refs; tags are copied as-is.
         for R of Info.Refs loop
            declare
               Name : constant String := To_String (R.Name);
            begin
               if Name = "HEAD" then
                  Head_Id := To_Unbounded_String (Version.Objects.To_String (R.Id));
               elsif Has_Prefix (Name, Heads_Prefix) then
                  Version.Refs.Atomic_Write_Ref
                    (Path      =>
                       Remote_Tracking_Ref_Path
                         (Repo, "origin",
                          Name (Name'First + Heads_Prefix'Length .. Name'Last)),
                     Object_Id => R.Id);
               elsif Has_Prefix (Name, Tags_Prefix) then
                  Version.Refs.Atomic_Write_Ref
                    (Path      =>
                       Version.Files.Join
                         (Version.Repository.Common_Git_Dir (Repo), Name),
                     Object_Id => R.Id);
               end if;
            end;
         end loop;

         --  Default branch, following git's guess_remote_head: prefer main
         --  then master when they carry HEAD's id (or HEAD is absent); else the
         --  first branch whose id equals HEAD's; else main/master/first.
         if Matches_Head ("main") then
            Default_Branch := To_Unbounded_String ("main");
         elsif Matches_Head ("master") then
            Default_Branch := To_Unbounded_String ("master");
         end if;

         if Length (Default_Branch) = 0 and then Length (Head_Id) > 0 then
            for R of Info.Refs loop
               declare
                  Name : constant String := To_String (R.Name);
               begin
                  if Has_Prefix (Name, Heads_Prefix)
                    and then Version.Objects.To_String (R.Id)
                             = To_String (Head_Id)
                  then
                     Default_Branch := To_Unbounded_String
                       (Name (Name'First + Heads_Prefix'Length .. Name'Last));
                     exit;
                  end if;
               end;
            end loop;
         end if;

         if Length (Default_Branch) = 0 then
            if Branch_Id ("main")'Length > 0 then
               Default_Branch := To_Unbounded_String ("main");
            elsif Branch_Id ("master")'Length > 0 then
               Default_Branch := To_Unbounded_String ("master");
            else
               for R of Info.Refs loop
                  declare
                     Name : constant String := To_String (R.Name);
                  begin
                     if Has_Prefix (Name, Heads_Prefix) then
                        Default_Branch := To_Unbounded_String
                          (Name (Name'First + Heads_Prefix'Length .. Name'Last));
                        exit;
                     end if;
                  end;
               end loop;
            end if;
         end if;

         if Length (Default_Branch) = 0 then
            raise Ada.IO_Exceptions.Data_Error
              with "bundle has no branch to check out";
         end if;

         Checkout_Fetched_Branch (Repo, To_String (Default_Branch));
      end Populate;
   begin
      if Target'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with "clone target must not be empty";
      end if;
      if Ada.Directories.Exists (Version.Files.To_Native_Path (Target)) then
         raise Ada.IO_Exceptions.Data_Error
           with "clone target already exists: " & Target;
      end if;
      if not Header.Complete then
         raise Ada.IO_Exceptions.Data_Error
           with "cannot clone from an incomplete bundle (has prerequisites)";
      end if;

      --  Object format follows the width of the bundle's ref ids.
      if not Header.Refs.Is_Empty
        and then Version.Objects.Id_Length
                   (Header.Refs.First_Element.Id) = 64
      then
         Object_Format := Version.Hash.Sha256;
      end if;

      Version.Init.Init (Target, Object_Format);
      begin
         Version.Files.With_Directory
           (Path => Target, Action => Populate'Access);
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
   end Clone_From_Bundle;

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
                  Set_Unborn_Default_Branch
                    (Repo => Repo, Branch => Default_Branch);
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

      --  A local source that is a plain file is a git bundle (git treats it the
      --  same way): unpack it instead of talking a transport.
      declare
         Local : constant String := Version.Transport.Strip_File_Scheme (Source);
      begin
         if Version.Files.Is_Ordinary_File
              (Version.Files.To_Native_Path (Local))
         then
            if Has_Depth or else Filter'Length > 0 then
               raise Ada.IO_Exceptions.Data_Error
                 with "clone --depth/--filter is not supported for a bundle";
            end if;
            Clone_From_Bundle (Local, Target);
            return;
         end if;
      end;

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
