with Ada.Directories; use Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;
with Ada.Containers; use Ada.Containers;
with Version.Files;
with Version.Object_Cache;
with Version.History;
with Version.Refs;
with Version.Reftable;
with Version.Repository;
with Version.Packed_Refs;
with Version.Ref_Names;
with Version.Ref_Transaction;
with Version.Revisions;
with Version.Transport.Local;
with Version.Write;

package body Version.Tags is
   use Version.Objects;

   use Tag_Name_Vectors;

   function Invalid_Tag_Name_Diagnostic
     (Name : String)
      return String
   is
   begin
      return "invalid tag name: " & Name;
   end Invalid_Tag_Name_Diagnostic;

   function Tag_Already_Exists_Diagnostic
     (Name : String)
      return String
   is
   begin
      return "tag already exists: " & Name;
   end Tag_Already_Exists_Diagnostic;

   function Tag_Does_Not_Exist_Diagnostic
     (Name : String)
      return String
   is
   begin
      return "tag does not exist: " & Name;
   end Tag_Does_Not_Exist_Diagnostic;

   function Invalid_Current_Commit_Id_Diagnostic return String is
   begin
      return "invalid current commit id";
   end Invalid_Current_Commit_Id_Diagnostic;

   function Empty_Tag_Message_Diagnostic return String is
   begin
      return "empty tag message";
   end Empty_Tag_Message_Diagnostic;

   function Tag_Path
     (Repo : Version.Repository.Repository_Handle; Name : String) return String
   is
   begin
      return
        Version.Files.Join
          (Version.Files.Join
             (Version.Repository.Common_Git_Dir (Repo), "refs/tags"),
           Name);
   end Tag_Path;

   function Is_Valid_Tag_Name (Name : String) return Boolean is
   begin
      return Version.Ref_Names.Is_Valid_Tag_Name (Name);
   end Is_Valid_Tag_Name;

   procedure Require_New_Tag
     (Repo : Version.Repository.Repository_Handle;
      Name : String)
   is
      Path : constant String := Tag_Path (Repo, Name);
   begin
      if not Is_Valid_Tag_Name (Name) then
         raise Ada.IO_Exceptions.Data_Error with Invalid_Tag_Name_Diagnostic (Name);
      end if;

      if Ada.Directories.Exists (Path)
        or else Version.Refs.Ref_Exists (Repo => Repo, Name => "refs/tags/" & Name)
      then
         raise Ada.IO_Exceptions.Data_Error with Tag_Already_Exists_Diagnostic (Name);
      end if;
   end Require_New_Tag;

   procedure Write_New_Tag_Ref
     (Repo      : Version.Repository.Repository_Handle;
      Name      : String;
      Object_Id : Version.Objects.Hex_Object_Id)
   is
      Zero_Id : constant String := "0000000000000000000000000000000000000000";
      Tx      : Version.Ref_Transaction.Transaction;
   begin
      Version.Ref_Transaction.Start (Tx, Repo);
      Version.Ref_Transaction.Add_Update
        (Item         => Tx,
         Ref_Name     => "refs/tags/" & Name,
         New_Id       => Object_Id,
         Expected_Old => Zero_Id);
      Version.Ref_Transaction.Commit (Tx);
   exception
      when others =>
         Version.Ref_Transaction.Cancel (Tx);
         raise;
   end Write_New_Tag_Ref;

   procedure Create_Tag
     (Name     : String;
      Revision : String)
   is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
   begin
      Require_New_Tag (Repo, Name);

      declare
         Target_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Revisions.Resolve (Repo => Repo, Text => Revision);
      begin
         Write_New_Tag_Ref
           (Repo      => Repo,
            Name      => Name,
            Object_Id => Target_Id);
      end;
   end Create_Tag;

   procedure Create_Tag (Name : String) is
      Repo      : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
      Commit_Id : constant String := Version.Refs.Current_Commit_Id (Repo);
   begin
      Require_New_Tag (Repo, Name);

      if not Version.Objects.Is_Valid_Hex_Object_Id (Commit_Id) then
         raise Ada.IO_Exceptions.Data_Error with Invalid_Current_Commit_Id_Diagnostic;
      end if;

      Write_New_Tag_Ref
        (Repo      => Repo,
         Name      => Name,
         Object_Id => Version.Objects.To_Object_Id (Commit_Id));
   end Create_Tag;

   procedure Create_Annotated_Tag
     (Name        : String;
      Revision    : String;
      Message     : String;
      Signing_Key : String := "")
   is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
   begin
      Require_New_Tag (Repo, Name);

      if Message'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with Empty_Tag_Message_Diagnostic;
      end if;

      declare
         Target_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Revisions.Resolve (Repo => Repo, Text => Revision);
         Tag_Id    : constant Version.Objects.Hex_Object_Id :=
           Version.Write.Write_Tag
             (Repo        => Repo,
              Target_Id   => Target_Id,
              Tag_Name    => Name,
              Message     => Message,
              Signing_Key => Signing_Key);
      begin
         Write_New_Tag_Ref
           (Repo      => Repo,
            Name      => Name,
            Object_Id => Tag_Id);
      end;
   end Create_Annotated_Tag;

   procedure Create_Annotated_Tag
     (Name        : String;
      Message     : String;
      Signing_Key : String := "")
   is
      Repo      : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
      Commit_Id : constant String := Version.Refs.Current_Commit_Id (Repo);
   begin
      Require_New_Tag (Repo, Name);

      if Message'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with Empty_Tag_Message_Diagnostic;
      end if;

      if not Version.Objects.Is_Valid_Hex_Object_Id (Commit_Id) then
         raise Ada.IO_Exceptions.Data_Error with Invalid_Current_Commit_Id_Diagnostic;
      end if;

      declare
         Tag_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Write.Write_Tag
             (Repo        => Repo,
              Target_Id   => Version.Objects.To_Object_Id (Commit_Id),
              Tag_Name    => Name,
              Message     => Message,
              Signing_Key => Signing_Key);
      begin
         Write_New_Tag_Ref
           (Repo      => Repo,
            Name      => Name,
            Object_Id => Tag_Id);
      end;
   end Create_Annotated_Tag;

   procedure Delete_Tag (Name : String) is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
   begin
      if not Is_Valid_Tag_Name (Name) then
         raise Ada.IO_Exceptions.Data_Error with Invalid_Tag_Name_Diagnostic (Name);
      end if;

      if not Version.Refs.Ref_Exists (Repo => Repo, Name => "refs/tags/" & Name)
      then
         raise Ada.IO_Exceptions.Data_Error with Tag_Does_Not_Exist_Diagnostic (Name);
      end if;

      declare
         Target_Id : constant Version.Objects.Hex_Object_Id := Resolve_Tag (Name);
         Tx        : Version.Ref_Transaction.Transaction;
      begin
         Version.Ref_Transaction.Start (Tx, Repo);
         Version.Ref_Transaction.Add_Delete
           (Item         => Tx,
            Ref_Name     => "refs/tags/" & Name,
            Expected_Old => To_String (Target_Id));
         Version.Ref_Transaction.Commit (Tx);
      exception
         when others =>
            Version.Ref_Transaction.Cancel (Tx);
            raise;
      end;
   end Delete_Tag;

   function Delete_Tag_Text (Name : String) return String is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
      Deleted_Id : constant Version.Objects.Hex_Object_Id := Resolve_Tag (Name);
      Full       : constant String := To_String (Deleted_Id);
      Short      : constant String :=
        Full (Full'First .. Full'First
              + Version.Revisions.Unique_Abbrev_Length (Repo, Deleted_Id, 7)
              - 1);
   begin
      Delete_Tag (Name);

      --  git's exact report line, abbreviating the old target the way
      --  find_unique_abbrev does.
      return "Deleted tag '" & Name & "' (was " & Short & ")";
   end Delete_Tag_Text;

   procedure Rename_Tag
     (Old_Name : String;
      New_Name : String)
   is
      Zero_Id : constant String := "0000000000000000000000000000000000000000";
      Repo    : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
      Old_Id  : constant Version.Objects.Hex_Object_Id := Resolve_Tag (Old_Name);
      Tx      : Version.Ref_Transaction.Transaction;
   begin
      Require_New_Tag (Repo, New_Name);

      Version.Ref_Transaction.Start (Tx, Repo);
      Version.Ref_Transaction.Add_Update
        (Item         => Tx,
         Ref_Name     => "refs/tags/" & New_Name,
         New_Id       => Old_Id,
         Expected_Old => Zero_Id);
      Version.Ref_Transaction.Add_Delete
        (Item         => Tx,
         Ref_Name     => "refs/tags/" & Old_Name,
         Expected_Old => To_String (Old_Id));
      Version.Ref_Transaction.Commit (Tx);
   exception
      when others =>
         Version.Ref_Transaction.Cancel (Tx);
         raise;
   end Rename_Tag;

   function Rename_Tag_Text
     (Old_Name : String;
      New_Name : String) return String
   is
      Old_Id : constant Version.Objects.Hex_Object_Id := Resolve_Tag (Old_Name);
   begin
      Rename_Tag (Old_Name => Old_Name, New_Name => New_Name);
      return
        "renamed tag " & Old_Name & " " & New_Name & " " & To_String (Old_Id);
   end Rename_Tag_Text;

   procedure Append_Tags_In_Directory
     (Directory_Path : String;
      Prefix         : String;
      Result         : in out Tag_Name_Vectors.Vector)
   is
      Search   : Ada.Directories.Search_Type;
      Dir_Item : Ada.Directories.Directory_Entry_Type;
      Opened   : Boolean := False;
   begin
      if not Ada.Directories.Exists (Directory_Path) then
         return;
      end if;

      Ada.Directories.Start_Search
        (Search    => Search,
         Directory => Directory_Path,
         Pattern   => "*",
         Filter    =>
           [Ada.Directories.Ordinary_File => True,
            Ada.Directories.Directory     => True,
            Ada.Directories.Special_File  => False]);

      Opened := True;

      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Dir_Item);

         declare
            Name : constant String := Ada.Directories.Simple_Name (Dir_Item);

            Full_Path : constant String :=
              Ada.Directories.Full_Name (Dir_Item);

            Tag_Name : constant String :=
              (if Prefix'Length = 0 then Name else Prefix & "/" & Name);
         begin
            if Name = "." or else Name = ".." then
               null;

            elsif Ada.Directories.Kind (Dir_Item) = Ada.Directories.Directory
            then
               Append_Tags_In_Directory
                 (Directory_Path => Full_Path,
                  Prefix         => Tag_Name,
                  Result         => Result);

            elsif Name'Length >= 5
              and then Name (Name'Last - 4 .. Name'Last) = ".lock"
            then
               null;

            elsif Is_Valid_Tag_Name (Tag_Name) then
               declare
                  Id_Text : constant String :=
                    Ada.Strings.Fixed.Trim
                      (Version.Transport.Local.Read_First_Line (Full_Path),
                       Ada.Strings.Both);
               begin
                  if Version.Objects.Is_Valid_Hex_Object_Id (Id_Text) then
                     Result.Append
                       (Ada.Strings.Unbounded.To_Unbounded_String (Tag_Name));
                  end if;
               end;
            end if;
         end;
      end loop;

      Ada.Directories.End_Search (Search);

   exception
      when others =>
         if Opened then
            Ada.Directories.End_Search (Search);
         end if;

         raise;
   end Append_Tags_In_Directory;

   procedure Sort_Tags (Tags : in out Tag_Name_Vectors.Vector) is

      Swapped : Boolean := True;
   begin
      if Tags.Length < 2 then
         return;
      end if;

      while Swapped loop
         Swapped := False;

         for I in Tags.First_Index .. Tags.Last_Index - 1 loop
            if To_String (Tags.Element (I + 1)) < To_String (Tags.Element (I))
            then
               declare
                  Temp : constant Unbounded_String := Tags.Element (I);
               begin
                  Tags.Replace_Element (I, Tags.Element (I + 1));
                  Tags.Replace_Element (I + 1, Temp);
                  Swapped := True;
               end;
            end if;
         end loop;
      end loop;
   end Sort_Tags;

   function Tag_Already_Listed
     (Tags : Tag_Name_Vectors.Vector; Name : String) return Boolean is
   begin
      if Tags.Is_Empty then
         return False;
      end if;

      for I in Tags.First_Index .. Tags.Last_Index loop
         if Ada.Strings.Unbounded.To_String (Tags.Element (I)) = Name then
            return True;
         end if;
      end loop;

      return False;
   end Tag_Already_Listed;

   procedure Append_Packed_Tags
     (Repo   : Version.Repository.Repository_Handle;
      Result : in out Tag_Name_Vectors.Vector)
   is
      Tags_Prefix : constant String := "refs/tags/";
      Refs        : constant Version.Packed_Refs.Packed_Ref_Vectors.Vector :=
        Version.Packed_Refs.Read_All (Repo);
   begin
      if Refs.Is_Empty then
         return;
      end if;

      for I in Refs.First_Index .. Refs.Last_Index loop
         declare
            Ref_Name : constant String :=
              Ada.Strings.Unbounded.To_String (Refs.Element (I).Name);
         begin
            if Ref_Name'Length >= Tags_Prefix'Length
              and then
                Ref_Name
                  (Ref_Name'First .. Ref_Name'First + Tags_Prefix'Length - 1)
                = Tags_Prefix
            then
               declare
                  Tag_Name : constant String :=
                    Ref_Name
                      (Ref_Name'First + Tags_Prefix'Length .. Ref_Name'Last);
               begin
                  if not Tag_Already_Listed (Result, Tag_Name) then
                     Result.Append
                       (Ada.Strings.Unbounded.To_Unbounded_String (Tag_Name));
                  end if;
               end;
            end if;
         end;
      end loop;
   end Append_Packed_Tags;

   function Tag_Exists (Name : String) return Boolean is
      Repo     : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
      Ref_Name : constant String := "refs/tags/" & Name;
   begin
      if not Is_Valid_Tag_Name (Name) then
         raise Ada.IO_Exceptions.Data_Error with Invalid_Tag_Name_Diagnostic (Name);
      end if;

      return Version.Refs.Ref_Exists (Repo => Repo, Name => Ref_Name);
   end Tag_Exists;

   function Resolve_Tag (Name : String) return Version.Objects.Hex_Object_Id is
      Repo     : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
      Ref_Name : constant String := "refs/tags/" & Name;
   begin
      if not Is_Valid_Tag_Name (Name) then
         raise Ada.IO_Exceptions.Data_Error with Invalid_Tag_Name_Diagnostic (Name);
      end if;

      if not Version.Refs.Ref_Exists (Repo => Repo, Name => Ref_Name) then
         raise Ada.IO_Exceptions.Data_Error with Tag_Does_Not_Exist_Diagnostic (Name);
      end if;

      return Version.Refs.Resolve_Ref (Repo => Repo, Name => Ref_Name);
   end Resolve_Tag;

   function Resolve_Tag_Text (Name : String) return String is
   begin
      return To_String (Resolve_Tag (Name)) & Character'Val (10);
   end Resolve_Tag_Text;

   function Peeled_Target_Id
     (Repo    : Version.Repository.Repository_Handle;
      Objects : in out Version.Object_Cache.Object_Cache;
      Id      : Version.Objects.Hex_Object_Id)
      return Version.Objects.Hex_Object_Id
   is
      Current : Version.Objects.Hex_Object_Id := Id;
   begin
      for Depth in 1 .. 100 loop
         declare
            Obj : constant Version.Objects.Git_Object :=
              Version.Object_Cache.Read_Object (Repo, Objects, Current);
         begin
            if Version.Objects.Kind (Obj) /= Version.Objects.Tag_Object then
               return Current;
            end if;

            Current := Version.Objects.Tag_Target_Id (Obj);
         end;
      end loop;

      raise Ada.IO_Exceptions.Data_Error with "tag reference chain too deep";
   end Peeled_Target_Id;

   function Peel_Tag (Name : String) return Version.Objects.Hex_Object_Id is
      Repo    : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
      Objects : Version.Object_Cache.Object_Cache;
   begin
      return Peeled_Target_Id
        (Repo    => Repo,
         Objects => Objects,
         Id      => Resolve_Tag (Name));
   end Peel_Tag;

   function Peel_Tag_Text (Name : String) return String is
   begin
      return To_String (Peel_Tag (Name)) & Character'Val (10);
   end Peel_Tag_Text;

   function Object_Kind_Name
     (Kind : Version.Objects.Object_Kind) return String
   is
   begin
      return
        (case Kind is
            when Version.Objects.Blob_Object    => "blob",
            when Version.Objects.Tree_Object    => "tree",
            when Version.Objects.Commit_Object  => "commit",
            when Version.Objects.Tag_Object     => "tag",
            when Version.Objects.Unknown_Object => "unknown");
   end Object_Kind_Name;

   function Tag_Header_Value
     (Text   : String;
      Prefix : String) return String
   is
      Line_Start : Positive := Text'First;
      Line_Stop  : Natural;
   begin
      while Line_Start <= Text'Last loop
         Line_Stop := Line_Start;

         while Line_Stop <= Text'Last
           and then Text (Line_Stop) /= Character'Val (10)
         loop
            Line_Stop := Line_Stop + 1;
         end loop;

         if Line_Stop > Line_Start
           and then Line_Stop - Line_Start >= Prefix'Length
           and then Text
             (Line_Start .. Line_Start + Prefix'Length - 1) = Prefix
         then
            return Text (Line_Start + Prefix'Length .. Line_Stop - 1);
         end if;

         exit when Line_Stop > Text'Last;
         Line_Start := Line_Stop + 1;
      end loop;

      raise Ada.IO_Exceptions.Data_Error
        with "corrupt tag: missing " & Prefix (Prefix'First .. Prefix'Last - 1);
   end Tag_Header_Value;

   function Tag_Message (Text : String) return String is
   begin
      for I in Text'First .. Text'Last - 1 loop
         if Text (I) = Character'Val (10)
           and then Text (I + 1) = Character'Val (10)
         then
            if I + 2 <= Text'Last then
               return Text (I + 2 .. Text'Last);
            else
               return "";
            end if;
         end if;
      end loop;

      raise Ada.IO_Exceptions.Data_Error with "corrupt tag: missing message";
   end Tag_Message;

   function Show_Tag_Text (Name : String) return String is
      Repo    : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
      Objects : Version.Object_Cache.Object_Cache;
      Id      : constant Version.Objects.Hex_Object_Id := Resolve_Tag (Name);
      Obj     : constant Version.Objects.Git_Object :=
        Version.Object_Cache.Read_Object (Repo, Objects, Id);
      Text    : Unbounded_String;
   begin
      Append (Text, "name " & Name & Character'Val (10));
      Append (Text, "object " & To_String (Id) & Character'Val (10));
      Append
        (Text,
         "type " & Object_Kind_Name (Version.Objects.Kind (Obj))
         & Character'Val (10));

      if Version.Objects.Kind (Obj) = Version.Objects.Tag_Object then
         declare
            Content     : constant String := Version.Objects.Content (Obj);
            Target_Id   : constant Version.Objects.Hex_Object_Id :=
              Version.Objects.Tag_Target_Id (Obj);
            Target      : constant Version.Objects.Git_Object :=
              Version.Object_Cache.Read_Object (Repo, Objects, Target_Id);
            Header_Type : constant String := Tag_Header_Value (Content, "type ");
            Message     : constant String := Tag_Message (Content);
         begin
            if Header_Type /= Object_Kind_Name (Version.Objects.Kind (Target)) then
               raise Ada.IO_Exceptions.Data_Error
                 with "corrupt tag: target type mismatch";
            end if;

            Append (Text, "target " & To_String (Target_Id) & Character'Val (10));
            Append (Text, "target-type " & Header_Type & Character'Val (10));
            Append (Text, "message" & Character'Val (10));
            Append (Text, Message);

            if Message'Length = 0
              or else Message (Message'Last) /= Character'Val (10)
            then
               Append (Text, Character'Val (10));
            end if;
         end;
      end if;

      return To_String (Text);
   end Show_Tag_Text;

   function Tagged_Object (Name : String) return Version.Objects.Git_Object is
      Repo    : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
      Objects : Version.Object_Cache.Object_Cache;
   begin
      return Version.Object_Cache.Read_Object (Repo, Objects, Resolve_Tag (Name));
   end Tagged_Object;

   function Tag_Message_Lines
     (Name  : String;
      Lines : Positive := 1)
      return String
   is
      Obj : constant Version.Objects.Git_Object := Tagged_Object (Name);

      --  Headers and message are separated by a blank line in both tag and
      --  commit objects, so Tag_Message splits either one. A lightweight tag
      --  shows the message of the commit it names.
      Message : constant String :=
        (if Version.Objects.Kind (Obj) in
           Version.Objects.Tag_Object | Version.Objects.Commit_Object
         then Tag_Message (Version.Objects.Content (Obj))
         else "");

      Result  : Unbounded_String;
      Start   : Positive := Message'First;
      Stop    : Natural;
      Emitted : Natural := 0;
   begin
      while Emitted < Lines and then Start <= Message'Last loop
         Stop := Start;

         while Stop <= Message'Last
           and then Message (Stop) /= Character'Val (10)
         loop
            Stop := Stop + 1;
         end loop;

         if Emitted > 0 then
            Append (Result, Character'Val (10) & "    ");
         end if;

         Append (Result, Message (Start .. Stop - 1));
         Emitted := Emitted + 1;
         Start := Stop + 1;
      end loop;

      return To_String (Result);
   end Tag_Message_Lines;

   function Tag_Object_Text (Name : String) return String is
      Obj : constant Version.Objects.Git_Object := Tagged_Object (Name);
   begin
      if Version.Objects.Kind (Obj) /= Version.Objects.Tag_Object then
         raise Ada.IO_Exceptions.Data_Error
           with Name & ": cannot verify a non-tag object of type "
                & Object_Kind_Name (Version.Objects.Kind (Obj)) & ".";
      end if;

      return Version.Objects.Content (Obj);
   end Tag_Object_Text;

   function Tag_Is_Signed (Name : String) return Boolean is
      Text : constant String := Tag_Object_Text (Name);
   begin
      --  git recognises a tag as signed by the armor header of any of the
      --  signature formats it supports.
      return
        Ada.Strings.Fixed.Index (Text, "-----BEGIN PGP SIGNATURE-----") > 0
        or else Ada.Strings.Fixed.Index
                  (Text, "-----BEGIN SSH SIGNATURE-----") > 0
        or else Ada.Strings.Fixed.Index
                  (Text, "-----BEGIN SIGNED MESSAGE-----") > 0;
   end Tag_Is_Signed;

   function List_Tags return Tag_Name_Vectors.Vector is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;

      Root : constant String :=
        Version.Files.Join
          (Version.Repository.Common_Git_Dir (Repo), "refs/tags");

      Result : Tag_Name_Vectors.Vector;

      Tags_Prefix : constant String := "refs/tags/";
   begin
      if Version.Reftable.Is_Reftable (Repo) then
         for R of Version.Reftable.Live_Refs (Repo) loop
            declare
               Name : constant String :=
                 Ada.Strings.Unbounded.To_String (R.Name);
            begin
               if Name'Length > Tags_Prefix'Length
                 and then Name (Name'First .. Name'First
                                  + Tags_Prefix'Length - 1) = Tags_Prefix
               then
                  Result.Append
                    (Ada.Strings.Unbounded.To_Unbounded_String
                       (Name (Name'First + Tags_Prefix'Length .. Name'Last)));
               end if;
            end;
         end loop;
         Sort_Tags (Result);
         return Result;
      end if;

      Append_Tags_In_Directory
        (Directory_Path => Root, Prefix => "", Result => Result);

      Append_Packed_Tags (Repo => Repo, Result => Result);

      Sort_Tags (Result);

      return Result;
   end List_Tags;

   function List_Tags_Points_At
     (Revision : String) return Tag_Name_Vectors.Vector
   is
      Repo       : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
      Objects    : Version.Object_Cache.Object_Cache;
      Tags       : constant Tag_Name_Vectors.Vector := List_Tags;
      Result     : Tag_Name_Vectors.Vector;

      Target_Id : constant Version.Objects.Hex_Object_Id :=
        Peeled_Target_Id
          (Repo, Objects, Version.Revisions.Resolve (Repo => Repo, Text => Revision));
   begin
      if Tags.Is_Empty then
         return Result;
      end if;

      for I in Tags.First_Index .. Tags.Last_Index loop
         declare
            Name : constant String :=
              Ada.Strings.Unbounded.To_String (Tags.Element (I));
         begin
            if Peeled_Target_Id (Repo, Objects, Resolve_Tag (Name)) = Target_Id then
               Result.Append (Tags.Element (I));
            end if;
         end;
      end loop;

      return Result;
   end List_Tags_Points_At;

   function List_Tags_Containing
     (Revision : String) return Tag_Name_Vectors.Vector
   is
      Repo      : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
      Objects   : Version.Object_Cache.Object_Cache;
      Tags      : constant Tag_Name_Vectors.Vector := List_Tags;
      Result    : Tag_Name_Vectors.Vector;

      Target_Id : constant Version.Objects.Hex_Object_Id :=
        Version.Revisions.Resolve_Commit (Repo => Repo, Text => Revision);
   begin
      if Tags.Is_Empty then
         return Result;
      end if;

      for I in Tags.First_Index .. Tags.Last_Index loop
         declare
            Name      : constant String :=
              Ada.Strings.Unbounded.To_String (Tags.Element (I));
            Peeled_Id : constant Version.Objects.Hex_Object_Id :=
              Peeled_Target_Id (Repo, Objects, Resolve_Tag (Name));
            Obj       : constant Version.Objects.Git_Object :=
              Version.Object_Cache.Read_Object (Repo, Objects, Peeled_Id);
         begin
            if Version.Objects.Kind (Obj) = Version.Objects.Commit_Object
              and then Version.History.Is_Ancestor
                (Repo       => Repo,
                 Base_Id    => Target_Id,
                 Derived_Id => Peeled_Id)
            then
               Result.Append (Tags.Element (I));
            end if;
         end;
      end loop;

      return Result;
   end List_Tags_Containing;

   function List_Tags_Containing_Text (Revision : String) return String is
      Tags : constant Tag_Name_Vectors.Vector :=
        List_Tags_Containing (Revision);
      Text : Unbounded_String;
   begin
      if not Tags.Is_Empty then
         for I in Tags.First_Index .. Tags.Last_Index loop
            Append (Text, Tags.Element (I));
            Append (Text, Character'Val (10));
         end loop;
      end if;

      return To_String (Text);
   end List_Tags_Containing_Text;

   function List_Tags_Points_At_Text (Revision : String) return String is
      Tags : constant Tag_Name_Vectors.Vector :=
        List_Tags_Points_At (Revision);
      Text : Unbounded_String;
   begin
      if not Tags.Is_Empty then
         for I in Tags.First_Index .. Tags.Last_Index loop
            Append (Text, Tags.Element (I));
            Append (Text, Character'Val (10));
         end loop;
      end if;

      return To_String (Text);
   end List_Tags_Points_At_Text;

end Version.Tags;
