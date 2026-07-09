with Ada.Calendar;
with Ada.Containers.Vectors;
with Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Strings.Unbounded;
with GNAT.OS_Lib;
with Ada.Containers; use Ada.Containers;

with Version.Files;
with Version.Compression;
with Version.Hash;
with Version.Refs;
with Version.Config;
with Version.Reflog;
with Version.Path_Safety;
with Version.Ref_Names;
with Version.Ref_Transaction;
with Version.Hooks;

package body Version.Write is
   use Version.Objects;

   use Ada.Strings.Unbounded;
   use type GNAT.OS_Lib.String_Access;

   function Current_Commit_Or_Zero
     (Repo : Version.Repository.Repository_Handle) return String
   is
      Current : constant String := Version.Refs.Current_Commit_Id (Repo);
   begin
      if Current'Length = 0 then
         return "0000000000000000000000000000000000000000";
      end if;

      return Current;

   exception
      when others =>
         return "0000000000000000000000000000000000000000";
   end Current_Commit_Or_Zero;

   function Join (Left, Right : String) return String renames Version.Files.Join;

   procedure Write_String_File (Path : String; Content : String) is
      File : Ada.Streams.Stream_IO.File_Type;

      Data :
        Ada.Streams.Stream_Element_Array
          (1 .. Ada.Streams.Stream_Element_Offset (Content'Length));
   begin
      for I in Content'Range loop
         Data (Ada.Streams.Stream_Element_Offset (I - Content'First + 1)) :=
           Ada.Streams.Stream_Element (Character'Pos (Content (I)));
      end loop;

      Version.Files.Create_Parent_Directories (Path);
      Ada.Streams.Stream_IO.Create
        (File, Ada.Streams.Stream_IO.Out_File, Version.Files.To_Native_Path (Path));

      Ada.Streams.Stream_IO.Write (File, Data);
      Ada.Streams.Stream_IO.Close (File);

   exception
      when others =>
         if Ada.Streams.Stream_IO.Is_Open (File) then
            Ada.Streams.Stream_IO.Close (File);
         end if;

         raise;
   end Write_String_File;

   function Message_After_Commit_Hooks
     (Repo      : Version.Repository.Repository_Handle;
      Message   : String;
      Run_Hooks : Boolean) return String is
   begin
      return Version.Hooks.Prepare_Commit_Message
        (Repo      => Repo,
         Message   => Message,
         Run_Hooks => Run_Hooks);
   end Message_After_Commit_Hooks;

   function Object_Id_For
     (Repo : Version.Repository.Repository_Handle;
      Kind : String; Content : String) return Version.Objects.Hex_Object_Id
   is
      Header : constant String :=
        Kind & Natural'Image (Content'Length) & Character'Val (0);

      Id : constant String :=
        Version.Hash.Object_Hash_Hex
          (Version.Repository.Algorithm (Repo), Header & Content);
   begin
      return Version.Objects.To_Object_Id (Id);
   end Object_Id_For;

   procedure Write_Loose_Object
     (Repo    : Version.Repository.Repository_Handle;
      Kind    : String;
      Content : String)
   is
      Header : constant String :=
        Kind & Natural'Image (Content'Length) & Character'Val (0);

      Raw : constant String := Header & Content;

      Compressed : constant String := Version.Compression.Deflate_Zlib (Raw);

      Id : constant Version.Objects.Hex_Object_Id :=
        Object_Id_For (Repo, Kind, Content);

      Obj_Dir : constant String :=
        Join
          (Join (Version.Repository.Common_Git_Dir (Repo), "objects"), To_String (Id) (1 .. 2));

      Obj_Path : constant String :=
        Join (Obj_Dir, To_String (Id) (3 .. To_String (Id)'Last));
   begin
      if not Ada.Directories.Exists (Obj_Dir) then
         Ada.Directories.Create_Directory (Obj_Dir);
      end if;

      if not Ada.Directories.Exists (Obj_Path) then
         Write_String_File (Obj_Path, Compressed);
      end if;
   end Write_Loose_Object;

   function Write_Blob
     (Repo : Version.Repository.Repository_Handle; Content : String)
      return Version.Objects.Hex_Object_Id
   is
      Id : constant Version.Objects.Hex_Object_Id :=
        Object_Id_For (Repo, "blob", Content);
   begin
      Write_Loose_Object (Repo => Repo, Kind => "blob", Content => Content);

      return Id;
   end Write_Blob;

   procedure Copy_Object
     (Source : Version.Repository.Repository_Handle;
      Target : Version.Repository.Repository_Handle;
      Id     : Version.Objects.Hex_Object_Id)
   is
      Obj  : constant Git_Object := Read_Object (Source, Id);
      Name : constant String :=
        (case Kind (Obj) is
            when Blob_Object   => "blob",
            when Tree_Object   => "tree",
            when Commit_Object => "commit",
            when Tag_Object    => "tag",
            when others        =>
               raise Ada.IO_Exceptions.Data_Error
                 with "cannot copy object of unknown kind: " & To_String (Id));
   begin
      Write_Loose_Object (Target, Name, Content (Obj));
   end Copy_Object;

   function Starts_With_Prefix
     (Path : Unbounded_String; Prefix : Unbounded_String) return Boolean
   is
      P  : constant String := To_String (Path);
      Pr : constant String := To_String (Prefix);
   begin
      if Length (Prefix) = 0 then
         return True;
      end if;

      return
        P'Length > Pr'Length
        and then P (P'First .. P'First + Pr'Length - 1) = Pr
        and then P (P'First + Pr'Length) = '/';
   end Starts_With_Prefix;

   function Strip_Prefix
     (Path : Unbounded_String; Prefix : Unbounded_String)
      return Unbounded_String
   is
      P  : constant String := To_String (Path);
      Pr : constant String := To_String (Prefix);
   begin
      if Length (Prefix) = 0 then
         return Path;
      end if;

      if not Starts_With_Prefix (Path, Prefix) then
         return Null_Unbounded_String;
      end if;

      return To_Unbounded_String (P (P'First + Pr'Length + 1 .. P'Last));
   end Strip_Prefix;

   function First_Component (Path : Unbounded_String) return Unbounded_String
   is
      P : constant String := To_String (Path);
   begin
      for I in P'Range loop
         if P (I) = '/' then
            return To_Unbounded_String (P (P'First .. I - 1));
         end if;
      end loop;

      return Path;
   end First_Component;

   function Has_Slash (Path : Unbounded_String) return Boolean is
      P : constant String := To_String (Path);
   begin
      for C of P loop
         if C = '/' then
            return True;
         end if;
      end loop;

      return False;
   end Has_Slash;

   package Component_Vectors is new
     Ada.Containers.Vectors
       (Index_Type   => Natural,
        Element_Type => Unbounded_String);

   procedure Add_Component
     (List : in out Component_Vectors.Vector; Name : Unbounded_String) is
   begin
      if Length (Name) = 0 then
         return;
      end if;

      if not List.Is_Empty then
         for I in List.First_Index .. List.Last_Index loop
            if To_String (List.Element (I)) = To_String (Name) then
               return;
            end if;
         end loop;
      end if;

      List.Append (Name);
   end Add_Component;

   procedure Sort_Components (List : in out Component_Vectors.Vector) is
      Swapped : Boolean := True;
   begin
      if List.Length < 2 then
         return;
      end if;

      while Swapped loop
         Swapped := False;

         for I in List.First_Index .. List.Last_Index - 1 loop
            if To_String (List.Element (I + 1)) < To_String (List.Element (I))
            then
               declare
                  Tmp : constant Unbounded_String := List.Element (I);
               begin
                  List.Replace_Element (I, List.Element (I + 1));

                  List.Replace_Element (I + 1, Tmp);

                  Swapped := True;
               end;
            end if;
         end loop;
      end loop;
   end Sort_Components;

   function Find_File_Entry
     (Entries : Version.Staging.Index_Entry_Vectors.Vector;
      Prefix  : Unbounded_String;
      Name    : Unbounded_String) return Natural is
   begin
      if Entries.Is_Empty then
         return Natural'Last;
      end if;

      for I in Entries.First_Index .. Entries.Last_Index loop
         if Entries.Element (I).Stage = 0 then
            declare
               Local_Path : constant Unbounded_String :=
                 Strip_Prefix (Entries.Element (I).Path, Prefix);
            begin
               if Length (Local_Path) > 0
                 and then not Has_Slash (Local_Path)
                 and then To_String (Local_Path) = To_String (Name)
               then
                  return I;
               end if;
            end;
         end if;
      end loop;

      return Natural'Last;
   end Find_File_Entry;

   function Collect_Components
     (Entries : Version.Staging.Index_Entry_Vectors.Vector;
      Prefix  : Unbounded_String) return Component_Vectors.Vector
   is
      Result : Component_Vectors.Vector;
   begin
      if Entries.Is_Empty then
         return Result;
      end if;

      for I in Entries.First_Index .. Entries.Last_Index loop
         if Entries.Element (I).Stage = 0 then
            declare
               Local_Path : constant Unbounded_String :=
                 Strip_Prefix (Entries.Element (I).Path, Prefix);
            begin
               if Length (Local_Path) > 0 then
                  Add_Component (Result, First_Component (Local_Path));
               end if;
            end;
         end if;
      end loop;

      Sort_Components (Result);

      return Result;
   end Collect_Components;

   function Write_Tree_For_Prefix
     (Repo    : Version.Repository.Repository_Handle;
      Entries : Version.Staging.Index_Entry_Vectors.Vector;
      Prefix  : Unbounded_String) return Version.Objects.Hex_Object_Id
   is
      Components : constant Component_Vectors.Vector :=
        Collect_Components (Entries => Entries, Prefix => Prefix);

      Content : Unbounded_String;
   begin
      if not Components.Is_Empty then
         for I in Components.First_Index .. Components.Last_Index loop
            declare
               Name : constant Unbounded_String := Components.Element (I);

               File_Pos : constant Natural :=
                 Find_File_Entry
                   (Entries => Entries, Prefix => Prefix, Name => Name);
            begin
               if File_Pos /= Natural'Last then
                  declare
                     E : constant Version.Staging.Index_Entry :=
                       Entries.Element (File_Pos);
                  begin
                     Append (Content, To_String (E.Mode));
                     Append (Content, " ");
                     Append (Content, To_String (Name));
                     Append (Content, Character'Val (0));
                     Append (Content, To_Raw (E.Id));
                  end;

               else
                  declare
                     Child_Prefix : constant Unbounded_String :=
                       (if Length (Prefix) = 0
                        then Name
                        else
                          To_Unbounded_String
                            (To_String (Prefix) & "/" & To_String (Name)));

                     Child_Tree : constant Version.Objects.Hex_Object_Id :=
                       Write_Tree_For_Prefix
                         (Repo    => Repo,
                          Entries => Entries,
                          Prefix  => Child_Prefix);
                  begin
                     Append (Content, "40000");
                     Append (Content, " ");
                     Append (Content, To_String (Name));
                     Append (Content, Character'Val (0));
                     Append (Content, To_Raw (Child_Tree));
                  end;
               end if;
            end;
         end loop;
      end if;

      declare
         Tree_Content : constant String := To_String (Content);

         Id : constant Version.Objects.Hex_Object_Id :=
           Object_Id_For (Repo, "tree", Tree_Content);
      begin
         Write_Loose_Object
           (Repo => Repo, Kind => "tree", Content => Tree_Content);

         return Id;
      end;
   end Write_Tree_For_Prefix;

   function Write_Tree_From_Index
     (Repo    : Version.Repository.Repository_Handle;
      Entries : Version.Staging.Index_Entry_Vectors.Vector)
      return Version.Objects.Hex_Object_Id is
   begin
      if not Entries.Is_Empty then
         for I in Entries.First_Index .. Entries.Last_Index loop
            declare
               Safe_Path : constant String :=
                 Version.Path_Safety.Normalize_Relative_Path
                   (To_String (Entries.Element (I).Path));
               pragma Unreferenced (Safe_Path);
            begin
               null;
            end;
         end loop;
      end if;

      return
        Write_Tree_For_Prefix
          (Repo => Repo, Entries => Entries, Prefix => Null_Unbounded_String);
   end Write_Tree_From_Index;

   function Natural_Image_No_Leading_Space (Value : Natural) return String is
      Image : constant String := Natural'Image (Value);
   begin
      return Image (Image'First + 1 .. Image'Last);
   end Natural_Image_No_Leading_Space;

   function Unix_Time_Image return String is
      Epoch : constant Ada.Calendar.Time :=
        Ada.Calendar.Time_Of (Year => 1970, Month => 1, Day => 1);

      Now : constant Ada.Calendar.Time := Ada.Calendar.Clock;

      Seconds : constant Natural := Natural (Ada.Calendar."-" (Now, Epoch));
   begin
      return Natural_Image_No_Leading_Space (Seconds);
   end Unix_Time_Image;

   function Timestamp_Line return String is
   begin
      return Unix_Time_Image & " +0000";
   end Timestamp_Line;

   function Commit_Header
     (Repo    : Version.Repository.Repository_Handle;
      Tree_Id : Version.Objects.Hex_Object_Id;
      Parents : Version.Objects.Object_Id_Vectors.Vector) return String
   is
      Content : Unbounded_String;
   begin
      Append (Content, "tree " & To_String (Tree_Id) & Character'Val (10));

      if not Parents.Is_Empty then
         for I in Parents.First_Index .. Parents.Last_Index loop
            Append
              (Content,
               "parent " & To_String (Parents.Element (I)) & Character'Val (10));
         end loop;
      end if;

      declare
         User : constant Version.Config.Identity :=
           Version.Config.User_Identity (Repo);

         Name : constant String := To_String (User.Name);

         Email : constant String := To_String (User.Email);

         Time_Text : constant String := Timestamp_Line;
      begin
         Append
           (Content,
            "author "
            & Name
            & " <"
            & Email
            & "> "
            & Time_Text
            & Character'Val (10));

         Append
           (Content,
            "committer "
            & Name
            & " <"
            & Email
            & "> "
            & Time_Text
            & Character'Val (10));
      end;

      return To_String (Content);
   end Commit_Header;

   function GPGSig_Header (Signature : String) return String is
      Content : Unbounded_String;
      First_Line : Boolean := True;
      Line_First : Natural := Signature'First;
      LF : constant Character := Character'Val (10);
   begin
      if Signature'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with "cannot sign commit: empty signature";
      end if;

      while Line_First <= Signature'Last loop
         declare
            Line_Stop : Natural := Line_First;
         begin
            while Line_Stop <= Signature'Last and then Signature (Line_Stop) /= LF loop
               Line_Stop := Line_Stop + 1;
            end loop;

            if First_Line then
               Append (Content, "gpgsig ");
               First_Line := False;
            else
               Append (Content, " ");
            end if;

            if Line_Stop > Line_First then
               Append (Content, Signature (Line_First .. Line_Stop - 1));
            end if;

            Append (Content, LF);
            Line_First := Line_Stop + 1;
         end;
      end loop;

      return To_String (Content);
   end GPGSig_Header;

   function Commit_Content_From_Header
     (Header    : String;
      Message   : String;
      Signature : String := "") return String
   is
      Content : Unbounded_String := To_Unbounded_String (Header);
   begin
      if Signature'Length > 0 then
         Append (Content, GPGSig_Header (Signature));
      end if;

      Append (Content, Character'Val (10));
      Append (Content, Message);
      Append (Content, Character'Val (10));

      return To_String (Content);
   end Commit_Content_From_Header;

   function Commit_Content
     (Repo      : Version.Repository.Repository_Handle;
      Tree_Id   : Version.Objects.Hex_Object_Id;
      Parents   : Version.Objects.Object_Id_Vectors.Vector;
      Message   : String;
      Signature : String := "") return String
   is
   begin
      return Commit_Content_From_Header
        (Header    => Commit_Header (Repo => Repo, Tree_Id => Tree_Id, Parents => Parents),
         Message   => Message,
         Signature => Signature);
   end Commit_Content;

   function Write_Commit_Content
     (Repo    : Version.Repository.Repository_Handle;
      Content : String) return Version.Objects.Hex_Object_Id
   is
      Id : constant Version.Objects.Hex_Object_Id :=
        Object_Id_For (Repo, "commit", Content);
   begin
      Write_Loose_Object (Repo => Repo, Kind => "commit", Content => Content);
      return Id;
   end Write_Commit_Content;

   procedure Require_Safe_Signing_Key (Signing_Key : String) is
   begin
      for C of Signing_Key loop
         if C = Character'Val (0)
           or else C = Character'Val (10)
           or else C = Character'Val (13)
         then
            raise Ada.IO_Exceptions.Data_Error with "invalid signing key";
         end if;
      end loop;
   end Require_Safe_Signing_Key;

   function Sign_Commit_Payload
     (Repo        : Version.Repository.Repository_Handle;
      Payload     : String;
      Signing_Key : String) return String
   is
      Input_Path : constant String :=
        Join (Version.Repository.Git_Dir (Repo), "VERSION_SIGN_INPUT");
      Output_Path : constant String :=
        Join (Version.Repository.Git_Dir (Repo), "VERSION_SIGN_SIGNATURE");
      Use_Key : constant Boolean :=
        Signing_Key'Length > 0 and then Signing_Key /= "default";
      Arg_Count : constant Positive := (if Use_Key then 7 else 5);
      Args : GNAT.OS_Lib.Argument_List (1 .. Arg_Count) := [others => null];
      Status : Integer;
      Next : Positive := Args'First;

      procedure Add_Arg (Value : String) is
      begin
         Args (Next) := new String'(Value);
         Next := Next + 1;
      end Add_Arg;

      procedure Free_Args is
      begin
         for I in Args'Range loop
            if Args (I) /= null then
               GNAT.OS_Lib.Free (Args (I));
               Args (I) := null;
            end if;
         end loop;
      end Free_Args;
   begin
      Version.Files.Delete_File_If_Exists (Input_Path);
      Version.Files.Delete_File_If_Exists (Output_Path);
      Version.Files.Write_Binary_File_Atomic (Path => Input_Path, Content => Payload);

      Add_Arg ("--armor");
      Add_Arg ("--detach-sign");
      if Use_Key then
         Add_Arg ("--local-user");
         Add_Arg (Signing_Key);
      end if;
      Add_Arg ("--output");
      Add_Arg (Output_Path);
      Add_Arg (Input_Path);

      declare
         Program : GNAT.OS_Lib.String_Access :=
           GNAT.OS_Lib.Locate_Exec_On_Path ("gpg");
      begin
         if Program = null then
            Free_Args;
            Version.Files.Delete_File_If_Exists (Input_Path);
            Version.Files.Delete_File_If_Exists (Output_Path);
            raise Ada.IO_Exceptions.Data_Error with "cannot sign commit: gpg not found";
         end if;
         Status := GNAT.OS_Lib.Spawn (Program_Name => Program.all, Args => Args);
         GNAT.OS_Lib.Free (Program);
      end;
      Free_Args;

      if Status /= 0 then
         Version.Files.Delete_File_If_Exists (Input_Path);
         Version.Files.Delete_File_If_Exists (Output_Path);
         raise Ada.IO_Exceptions.Data_Error with "cannot sign commit: gpg failed";
      end if;

      declare
         Signature : constant String := Version.Files.Read_Binary_File (Output_Path);
      begin
         Version.Files.Delete_File_If_Exists (Input_Path);
         Version.Files.Delete_File_If_Exists (Output_Path);
         return Signature;
      end;
   exception
      when others =>
         Free_Args;
         Version.Files.Delete_File_If_Exists (Input_Path);
         Version.Files.Delete_File_If_Exists (Output_Path);
         raise;
   end Sign_Commit_Payload;

   function Write_Commit_With_Parents
     (Repo    : Version.Repository.Repository_Handle;
      Tree_Id : Version.Objects.Hex_Object_Id;
      Parents : Version.Objects.Object_Id_Vectors.Vector;
      Message : String) return Version.Objects.Hex_Object_Id
   is
      Commit_Text : constant String :=
        Commit_Content
          (Repo => Repo, Tree_Id => Tree_Id, Parents => Parents, Message => Message);
   begin
      return Write_Commit_Content (Repo => Repo, Content => Commit_Text);
   end Write_Commit_With_Parents;

   function Write_Commit_With_Author
     (Repo    : Version.Repository.Repository_Handle;
      Tree_Id : Version.Objects.Hex_Object_Id;
      Parents : Version.Objects.Object_Id_Vectors.Vector;
      Author  : String;
      Message : String) return Version.Objects.Hex_Object_Id
   is
      LF     : constant Character := Character'Val (10);
      User   : constant Version.Config.Identity :=
        Version.Config.User_Identity (Repo);
      Time   : constant String := Timestamp_Line;
      Header : Unbounded_String;
   begin
      Append (Header, "tree " & To_String (Tree_Id) & LF);
      for I in Parents.First_Index .. Parents.Last_Index loop
         Append (Header, "parent " & To_String (Parents.Element (I)) & LF);
      end loop;
      Append (Header, "author " & Author & LF);
      Append
        (Header,
         "committer " & To_String (User.Name) & " <"
         & To_String (User.Email) & "> " & Time & LF);
      return Write_Commit_Content
        (Repo    => Repo,
         Content => Commit_Content_From_Header
                      (Header => To_String (Header), Message => Message));
   end Write_Commit_With_Author;

   function Write_Signed_Commit_With_Parents
     (Repo        : Version.Repository.Repository_Handle;
      Tree_Id     : Version.Objects.Hex_Object_Id;
      Parents     : Version.Objects.Object_Id_Vectors.Vector;
      Message     : String;
      Signing_Key : String) return Version.Objects.Hex_Object_Id
   is
      Header : constant String :=
        Commit_Header (Repo => Repo, Tree_Id => Tree_Id, Parents => Parents);
      Unsigned_Content : constant String :=
        Commit_Content_From_Header (Header => Header, Message => Message);
   begin
      Require_Safe_Signing_Key (Signing_Key);

      declare
         Signature : constant String :=
           Sign_Commit_Payload
             (Repo => Repo, Payload => Unsigned_Content, Signing_Key => Signing_Key);

         Signed_Content : constant String :=
           Commit_Content_From_Header
             (Header    => Header,
              Message   => Message,
              Signature => Signature);
      begin
         return Write_Commit_Content (Repo => Repo, Content => Signed_Content);
      end;
   end Write_Signed_Commit_With_Parents;

   function Write_Tag
     (Repo        : Version.Repository.Repository_Handle;
      Target_Id   : Version.Objects.Hex_Object_Id;
      Tag_Name    : String;
      Message     : String;
      Signing_Key : String := "") return Version.Objects.Hex_Object_Id
   is
      Content : Unbounded_String;
      Target  : constant Version.Objects.Git_Object :=
        Version.Objects.Read_Object (Repo, Target_Id);
      Type_Name : constant String :=
        (case Version.Objects.Kind (Target) is
            when Version.Objects.Commit_Object  => "commit",
            when Version.Objects.Tree_Object    => "tree",
            when Version.Objects.Blob_Object    => "blob",
            when Version.Objects.Tag_Object     => "tag",
            when Version.Objects.Unknown_Object => "");
   begin
      if Type_Name'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with "cannot tag unknown object kind";
      end if;

      Version.Ref_Names.Require_Tag_Name (Tag_Name);
      Append (Content, "object " & To_String (Target_Id) & Character'Val (10));
      Append (Content, "type " & Type_Name & Character'Val (10));
      Append (Content, "tag " & Tag_Name & Character'Val (10));

      declare
         User : constant Version.Config.Identity :=
           Version.Config.User_Identity (Repo);
         Name : constant String := To_String (User.Name);
         Email : constant String := To_String (User.Email);
      begin
         Append
           (Content,
            "tagger " & Name & " <" & Email & "> " & Timestamp_Line
            & Character'Val (10));
      end;

      Append (Content, Character'Val (10));
      Append (Content, Message);
      Append (Content, Character'Val (10));

      --  Signed tags append the ASCII-armored PGP signature (over everything
      --  above) after the message, matching git `tag -s`.
      if Signing_Key'Length > 0 then
         Append
           (Content,
            Sign_Commit_Payload
              (Repo        => Repo,
               Payload     => To_String (Content),
               Signing_Key => Signing_Key));
      end if;

      declare
         Tag_Content : constant String := To_String (Content);
         Id : constant Version.Objects.Hex_Object_Id :=
           Object_Id_For (Repo, "tag", Tag_Content);
      begin
         Write_Loose_Object (Repo => Repo, Kind => "tag", Content => Tag_Content);
         return Id;
      end;
   end Write_Tag;

   function Write_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Tree_Id   : Version.Objects.Hex_Object_Id;
      Parent_Id : String;
      Message   : String) return Version.Objects.Hex_Object_Id
   is
      Parents : Version.Objects.Object_Id_Vectors.Vector;
   begin
      if Parent_Id'Length > 0 then
         if not Version.Objects.Is_Valid_Hex_Object_Id (Parent_Id) then
            raise Ada.IO_Exceptions.Data_Error with "invalid parent commit id";
         end if;

         Parents.Append (Version.Objects.To_Object_Id (Parent_Id));
      end if;

      return
        Write_Commit_With_Parents
          (Repo    => Repo,
           Tree_Id => Tree_Id,
           Parents => Parents,
           Message => Message);
   end Write_Commit;
   procedure Write_Branch_Commit
     (Repo         : Version.Repository.Repository_Handle;
      Branch_Name  : String;
      Commit       : Version.Objects.Hex_Object_Id;
      Expected_Old : String)
   is
      Tx : Version.Ref_Transaction.Transaction;
   begin
      Version.Ref_Names.Require_Branch_Name (Branch_Name);

      Version.Ref_Transaction.Start (Tx, Repo);
      Version.Ref_Transaction.Add_Update
        (Item         => Tx,
         Ref_Name     => "refs/heads/" & Branch_Name,
         New_Id       => Commit,
         Expected_Old => Expected_Old);
      Version.Ref_Transaction.Commit (Tx);
   exception
      when others =>
         Version.Ref_Transaction.Cancel (Tx);
         raise;
   end Write_Branch_Commit;

   function Same_Tree_As_HEAD
     (Repo    : Version.Repository.Repository_Handle;
      Tree_Id : Version.Objects.Hex_Object_Id;
      Head_Id : String)
      return Boolean
   is
   begin
      if Head_Id'Length = 0 then
         return False;
      end if;

      declare
         Head_Obj : constant Version.Objects.Git_Object :=
           Version.Objects.Read_Object
             (Repo, Version.Objects.To_Object_Id (Head_Id));
      begin
         return Version.Objects.Commit_Tree_Id (Head_Obj) = Tree_Id;
      end;
   end Same_Tree_As_HEAD;

   function Current_Parent_Id
     (Repo : Version.Repository.Repository_Handle) return String
   is
      Current : constant String := Version.Refs.Current_Commit_Id (Repo);
   begin
      if Current'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with "cannot amend unborn branch";
      end if;

      declare
         Current_Obj : constant Version.Objects.Git_Object :=
           Version.Objects.Read_Object
             (Repo, Version.Objects.To_Object_Id (Current));
      begin
         return Version.Objects.Commit_Parent_Id (Current_Obj);
      end;
   end Current_Parent_Id;

   procedure Advance_HEAD_After_Save
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Old_Id    : String;
      Message   : String)
   is
      Head : constant Version.Refs.Head_Info := Version.Refs.Read_Head (Repo);
   begin
      if Version.Refs.Is_Attached (Head) then
         declare
            Branch_Name : constant String := Version.Refs.Branch_Name (Head);
            Branch_Ref  : constant String := "refs/heads/" & Branch_Name;
            Branch_Moved : Boolean := False;
         begin
            Version.Ref_Names.Require_Branch_Name (Branch_Name);
            Version.Ref_Names.Require_Ref_Name (Branch_Ref);
            Version.Reflog.Preflight_Append
              (Repo, "HEAD", Version.Reflog.Data_Error_On_Lock);
            Version.Reflog.Preflight_Append
              (Repo, Branch_Ref, Version.Reflog.Data_Error_On_Lock);

            Write_Branch_Commit
              (Repo         => Repo,
               Branch_Name  => Branch_Name,
               Commit       => Commit_Id,
               Expected_Old => Old_Id);
            Branch_Moved := True;

            Version.Reflog.Append
              (Repo    => Repo,
               Ref     => "HEAD",
               Old_Id  => Old_Id,
               New_Id  => To_String (Commit_Id),
               Message => Message);

            Version.Reflog.Append
              (Repo    => Repo,
               Ref     => Branch_Ref,
               Old_Id  => Old_Id,
               New_Id  => To_String (Commit_Id),
               Message => Message);
         exception
            when others =>
               if Branch_Moved then
                  begin
                     Write_Branch_Commit
                       (Repo         => Repo,
                        Branch_Name  => Branch_Name,
                        Commit       => Version.Objects.To_Object_Id (Old_Id),
                        Expected_Old => To_String (Commit_Id));
                  exception
                     when others =>
                        null;
                  end;
               end if;

               raise;
         end;
      else
         declare
            Head_Moved : Boolean := False;
         begin
            Version.Reflog.Preflight_Append
              (Repo, "HEAD", Version.Reflog.Data_Error_On_Lock);

            Version.Refs.Write_Detached_HEAD
              (Repo         => Repo,
               Commit_Id    => Commit_Id,
               Expected_Old => Version.Objects.To_Object_Id (Old_Id));
            Head_Moved := True;

            Version.Reflog.Append
              (Repo    => Repo,
               Ref     => "HEAD",
               Old_Id  => Old_Id,
               New_Id  => To_String (Commit_Id),
               Message => Message);
         exception
            when others =>
               if Head_Moved then
                  begin
                     Version.Refs.Write_Detached_HEAD
                       (Repo         => Repo,
                        Commit_Id    => Version.Objects.To_Object_Id (Old_Id),
                        Expected_Old => Commit_Id);
                  exception
                     when others =>
                        null;
                  end;
               end if;

               raise;
         end;
      end if;
   end Advance_HEAD_After_Save;

   procedure Save_Amend (Message : String; Run_Hooks : Boolean := True) is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;

      Index : constant Version.Staging.Index_Entry_Vectors.Vector :=
        Version.Staging.Load (Repo);

      Old_Id : constant String := Current_Commit_Or_Zero (Repo);

      Parent : constant String := Current_Parent_Id (Repo);

      Final_Message : constant String :=
        Message_After_Commit_Hooks
          (Repo      => Repo,
           Message   => Message,
           Run_Hooks => Run_Hooks);

      Tree_Id : constant Version.Objects.Hex_Object_Id :=
        Write_Tree_From_Index (Repo, Index);

      Commit_Id : constant Version.Objects.Hex_Object_Id :=
        Write_Commit
          (Repo      => Repo,
           Tree_Id   => Tree_Id,
           Parent_Id => Parent,
           Message   => Final_Message);
   begin
      Advance_HEAD_After_Save
        (Repo      => Repo,
         Commit_Id => Commit_Id,
         Old_Id    => Old_Id,
         Message   => "save --amend: " & Final_Message);
      Version.Hooks.Run_Post_Commit (Repo => Repo, Run_Hooks => Run_Hooks);
   end Save_Amend;

   procedure Save (Message : String; Run_Hooks : Boolean := True) is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;

      Index : constant Version.Staging.Index_Entry_Vectors.Vector :=
        Version.Staging.Load (Repo);

      Parent : constant String := Version.Refs.Current_Commit_Id (Repo);

      Old_Id : constant String := Current_Commit_Or_Zero (Repo);

      Tree_Id : constant Version.Objects.Hex_Object_Id :=
        Write_Tree_From_Index (Repo, Index);
   begin
      if Same_Tree_As_HEAD (Repo => Repo, Tree_Id => Tree_Id, Head_Id => Parent) then
         return;
      end if;

      declare
         Final_Message : constant String :=
           Message_After_Commit_Hooks
             (Repo      => Repo,
              Message   => Message,
              Run_Hooks => Run_Hooks);

         Commit_Id : constant Version.Objects.Hex_Object_Id :=
           Write_Commit
             (Repo      => Repo,
              Tree_Id   => Tree_Id,
              Parent_Id => Parent,
              Message   => Final_Message);
      begin
         Advance_HEAD_After_Save
           (Repo      => Repo,
            Commit_Id => Commit_Id,
            Old_Id    => Old_Id,
            Message   => "save: " & Final_Message);
         Version.Hooks.Run_Post_Commit (Repo => Repo, Run_Hooks => Run_Hooks);
      end;
   end Save;

end Version.Write;
