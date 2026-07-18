with Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;
with Ada.Text_IO;

with Version.Files;

package body Version.Merge_State is
   use Version.Objects;

   use Ada.Strings.Unbounded;
   use type Ada.Directories.File_Kind;

   Null_Object_Id : constant Version.Objects.Hex_Object_Id :=
     Version.Objects.Zero_Object_Id;

   function Merge_State_Path
     (Repo : Version.Repository.Repository_Handle) return String is
   begin
      return Version.Files.Join
        (Version.Repository.Git_Dir (Repo), "VERSION_MERGE");
   end Merge_State_Path;

   function Git_State_Path
     (Repo : Version.Repository.Repository_Handle; Name : String) return String is
   begin
      return Version.Files.Join (Version.Repository.Git_Dir (Repo), Name);
   end Git_State_Path;

   function State_Exists
     (Repo : Version.Repository.Repository_Handle) return Boolean is
   begin
      return Ada.Directories.Exists (Merge_State_Path (Repo));
   end State_Exists;

   function Git_State_Exists
     (Repo : Version.Repository.Repository_Handle) return Boolean is
   begin
      return Ada.Directories.Exists (Git_State_Path (Repo, "MERGE_HEAD"))
        or else Ada.Directories.Exists (Git_State_Path (Repo, "SQUASH_MSG"));
   end Git_State_Exists;

   function With_Final_LF (Text : String) return String is
   begin
      if Text'Length = 0 then
         return Character'Val (10) & "";
      elsif Text (Text'Last) = Character'Val (10) then
         return Text;
      else
         return Text & Character'Val (10);
      end if;
   end With_Final_LF;

   function Default_Message (Target_Branch : String) return String is
   begin
      return "Merge " & Target_Branch;
   end Default_Message;

   procedure Write_Orig_Head
     (Repo       : Version.Repository.Repository_Handle;
      Current_Id : Version.Objects.Hex_Object_Id) is
   begin
      Version.Files.Write_Binary_File_Atomic
        (Path    => Git_State_Path (Repo, "ORIG_HEAD"),
         Content => To_String (Current_Id) & Character'Val (10));
   end Write_Orig_Head;

   procedure Write_Git_State
     (Repo          : Version.Repository.Repository_Handle;
      Current_Id    : Version.Objects.Hex_Object_Id;
      Target_Id     : Version.Objects.Hex_Object_Id;
      Target_Branch : String;
      Message       : String;
      Mode          : String)
   is
      Message_Text : constant String :=
        (if Message'Length = 0 then Default_Message (Target_Branch) else Message);
   begin
      Write_Orig_Head (Repo => Repo, Current_Id => Current_Id);

      if Ada.Strings.Fixed.Index (Mode, "squash") = 0 then
         Version.Files.Write_Binary_File_Atomic
           (Path    => Git_State_Path (Repo, "MERGE_HEAD"),
            Content => To_String (Target_Id) & Character'Val (10));
      else
         Version.Files.Delete_File_If_Exists (Git_State_Path (Repo, "MERGE_HEAD"));
         Version.Files.Write_Binary_File_Atomic
           (Path    => Git_State_Path (Repo, "SQUASH_MSG"),
            Content => With_Final_LF (Message_Text));
      end if;

      Version.Files.Write_Binary_File_Atomic
        (Path    => Git_State_Path (Repo, "MERGE_MSG"),
         Content => With_Final_LF (Message_Text));

      if Mode'Length > 0 then
         Version.Files.Write_Binary_File_Atomic
           (Path    => Git_State_Path (Repo, "MERGE_MODE"),
            Content => With_Final_LF (Mode));
      else
         Version.Files.Delete_File_If_Exists (Git_State_Path (Repo, "MERGE_MODE"));
      end if;
   end Write_Git_State;

   function Git_Message_Text
     (Repo : Version.Repository.Repository_Handle; Fallback : String) return String
   is
      Path : constant String := Git_State_Path (Repo, "MERGE_MSG");
   begin
      if Ada.Directories.Exists (Path)
        and then Ada.Directories.Kind (Path) = Ada.Directories.Ordinary_File
      then
         return Version.Files.Read_Binary_File (Path);
      else
         return Fallback;
      end if;
   end Git_Message_Text;

   function Git_Mode_Text
     (Repo : Version.Repository.Repository_Handle) return String
   is
      Path : constant String := Git_State_Path (Repo, "MERGE_MODE");
   begin
      if Ada.Directories.Exists (Path)
        and then Ada.Directories.Kind (Path) = Ada.Directories.Ordinary_File
      then
         return Version.Files.Read_Binary_File (Path);
      else
         return "";
      end if;
   end Git_Mode_Text;

   procedure Require_Id (Text : String; Field : String) is
   begin
      if not Version.Objects.Is_Valid_Hex_Object_Id (Text) then
         raise Ada.IO_Exceptions.Data_Error with
           "invalid merge state: " & Field;
      end if;
   end Require_Id;

   function Id_After_Prefix (Line : String; Prefix : String; Field : String)
      return Version.Objects.Hex_Object_Id
   is
   begin
      if Line'Length <= Prefix'Length
        or else Line (Line'First .. Line'First + Prefix'Length - 1) /= Prefix
      then
         raise Ada.IO_Exceptions.Data_Error with
           "invalid merge state: " & Field;
      end if;

      declare
         --  Id runs from after the prefix to end of line; Require_Id validates
         --  its width (40 or 64 hex).
         Text : constant String := Line (Line'First + Prefix'Length .. Line'Last);
      begin
         Require_Id (Text, Field);
         return Version.Objects.To_Object_Id (Text);
      end;
   end Id_After_Prefix;

   function Text_After_Prefix (Line : String; Prefix : String; Field : String)
      return String
   is
   begin
      if Line'Length < Prefix'Length
        or else Line (Line'First .. Line'First + Prefix'Length - 1) /= Prefix
      then
         raise Ada.IO_Exceptions.Data_Error with
           "invalid merge state: " & Field;
      end if;

      return Line (Line'First + Prefix'Length .. Line'Last);
   end Text_After_Prefix;

   procedure Require_State_Text (Text : String; Field : String) is
   begin
      if Text'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with
           "invalid merge state: " & Field;
      end if;

      for C of Text loop
         if C = Character'Val (0)
           or else C = Character'Val (10)
           or else C = Character'Val (13)
         then
            raise Ada.IO_Exceptions.Data_Error with
              "invalid merge state: " & Field;
         end if;
      end loop;
   end Require_State_Text;

   procedure Write_State
     (Repo          : Version.Repository.Repository_Handle;
      Current_Id    : Version.Objects.Hex_Object_Id;
      Target_Id     : Version.Objects.Hex_Object_Id;
      Target_Branch : String;
      Git_State     : Boolean := False;
      Message       : String := "";
      Mode          : String := "") is
      Empty : Version.Merge.Conflict_Vectors.Vector;
   begin
      Write_State
        (Repo          => Repo,
         Current_Id    => Current_Id,
         Target_Id     => Target_Id,
         Base_Id       => Null_Object_Id,
         Target_Branch => Target_Branch,
         Conflicts     => Empty,
         Git_State     => Git_State,
         Message       => Message,
         Mode          => Mode);
   end Write_State;

   procedure Write_State
     (Repo          : Version.Repository.Repository_Handle;
      Current_Id    : Version.Objects.Hex_Object_Id;
      Target_Id     : Version.Objects.Hex_Object_Id;
      Base_Id       : Version.Objects.Hex_Object_Id;
      Target_Branch : String;
      Conflicts     : Version.Merge.Conflict_Vectors.Vector;
      Git_State     : Boolean := False;
      Message       : String := "";
      Mode          : String := "")
   is
      Path : constant String := Merge_State_Path (Repo);
      Content : Unbounded_String;
   begin
      Require_State_Text (Target_Branch, "target branch");

      Content := To_Unbounded_String
        ("version 2" & Character'Val (10)
         & "current " & To_String (Current_Id) & Character'Val (10)
         & "target " & To_String (Target_Id) & Character'Val (10)
         & "base " & To_String (Base_Id) & Character'Val (10)
         & "branch " & Target_Branch & Character'Val (10));

      if Ada.Directories.Exists (Path) then
         raise Ada.IO_Exceptions.Data_Error with "merge state already exists";
      end if;

      if not Conflicts.Is_Empty then
         for I in Conflicts.First_Index .. Conflicts.Last_Index loop
            declare
               C : constant Version.Merge.Conflict := Conflicts.Element (I);
            begin
               Version.Merge.Require_Safe_Path (To_String (C.Path));

               Append
                 (Content,
                  "conflict "
                  & Version.Merge.Conflict_Kind_Image (C.Kind)
                  & " "
                  & To_String (C.Path)
                  & Character'Val (10));
            end;
         end loop;
      end if;

      Version.Files.Write_Binary_File_Atomic
        (Path => Path, Content => To_String (Content));

      if Git_State then
         Write_Git_State
           (Repo          => Repo,
            Current_Id    => Current_Id,
            Target_Id     => Target_Id,
            Target_Branch => Target_Branch,
            Message       => Message,
            Mode          => Mode);
      end if;
   end Write_State;

   procedure Read_Old_State
     (File          : in out Ada.Text_IO.File_Type;
      First_Line    : String;
      Current_Id    : out Version.Objects.Hex_Object_Id;
      Target_Id     : out Version.Objects.Hex_Object_Id;
      Base_Id       : out Version.Objects.Hex_Object_Id;
      Target_Branch : out Unbounded_String;
      Conflicts     : in out Version.Merge.Conflict_Vectors.Vector) is
      Target_Text : constant String := Ada.Text_IO.Get_Line (File);
      Branch_Text : constant String := Ada.Text_IO.Get_Line (File);
   begin
      Require_Id (First_Line, "current parent id");
      Require_Id (Target_Text, "target parent id");

      Current_Id := Version.Objects.To_Object_Id (First_Line);
      Target_Id := Version.Objects.To_Object_Id (Target_Text);
      Base_Id := Null_Object_Id;
      Require_State_Text (Branch_Text, "target branch");
      Target_Branch := To_Unbounded_String (Branch_Text);
      Conflicts.Clear;
   end Read_Old_State;

   procedure Read_New_State
     (File          : in out Ada.Text_IO.File_Type;
      Current_Id    : out Version.Objects.Hex_Object_Id;
      Target_Id     : out Version.Objects.Hex_Object_Id;
      Base_Id       : out Version.Objects.Hex_Object_Id;
      Target_Branch : out Unbounded_String;
      Conflicts     : in out Version.Merge.Conflict_Vectors.Vector) is
      Current_Line : constant String := Ada.Text_IO.Get_Line (File);
      Target_Line  : constant String := Ada.Text_IO.Get_Line (File);
      Base_Line    : constant String := Ada.Text_IO.Get_Line (File);
      Branch_Line  : constant String := Ada.Text_IO.Get_Line (File);
   begin
      Current_Id := Id_After_Prefix (Current_Line, "current ", "current parent id");
      Target_Id := Id_After_Prefix (Target_Line, "target ", "target parent id");
      Base_Id := Id_After_Prefix (Base_Line, "base ", "base id");
      declare
         Branch_Text : constant String :=
           Text_After_Prefix (Branch_Line, "branch ", "target branch");
      begin
         Require_State_Text (Branch_Text, "target branch");
         Target_Branch := To_Unbounded_String (Branch_Text);
      end;

      Conflicts.Clear;

      while not Ada.Text_IO.End_Of_File (File) loop
         declare
            Line : constant String := Ada.Text_IO.Get_Line (File);
         begin
            if Line'Length > 0 then
               if Line'Length < 10
                 or else Line (Line'First .. Line'First + 8) /= "conflict "
               then
                  raise Ada.IO_Exceptions.Data_Error with
                    "invalid merge state: conflict line";
               end if;

               declare
                  Rest : constant String := Line (Line'First + 9 .. Line'Last);
                  Space : constant Natural := Ada.Strings.Fixed.Index (Rest, " ");
               begin
                  if Space = 0 then
                     raise Ada.IO_Exceptions.Data_Error with
                       "invalid merge state: conflict path";
                  end if;

                  declare
                     Conflict_Path : constant String := Rest (Space + 1 .. Rest'Last);
                  begin
                     Version.Merge.Require_Safe_Path (Conflict_Path);

                     Conflicts.Append
                       (Version.Merge.Conflict'
                          (Kind => Version.Merge.Conflict_Kind_Value
                             (Rest (Rest'First .. Space - 1)),
                           Path => To_Unbounded_String (Conflict_Path)));
                  end;
               end;
            end if;
         end;
      end loop;
   end Read_New_State;

   procedure Read_State
     (Repo          : Version.Repository.Repository_Handle;
      Current_Id    : out Version.Objects.Hex_Object_Id;
      Target_Id     : out Version.Objects.Hex_Object_Id;
      Base_Id       : out Version.Objects.Hex_Object_Id;
      Target_Branch : out Unbounded_String;
      Conflicts     : in out Version.Merge.Conflict_Vectors.Vector)
   is
      Path : constant String := Merge_State_Path (Repo);
      File : Ada.Text_IO.File_Type;
   begin
      if not Ada.Directories.Exists (Path) then
         raise Ada.IO_Exceptions.Data_Error with "no integration to finalize";
      end if;

      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Version.Files.To_Native_Path (Path));

      declare
         First_Line : constant String := Ada.Text_IO.Get_Line (File);
      begin
         if First_Line = "version 2" then
            Read_New_State
              (File, Current_Id, Target_Id, Base_Id, Target_Branch, Conflicts);
         else
            Read_Old_State
              (File, First_Line, Current_Id, Target_Id, Base_Id,
               Target_Branch, Conflicts);
         end if;
      end;

      Ada.Text_IO.Close (File);

   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         raise;
   end Read_State;

   procedure Read_State
     (Repo          : Version.Repository.Repository_Handle;
      Current_Id    : out Version.Objects.Hex_Object_Id;
      Target_Id     : out Version.Objects.Hex_Object_Id;
      Target_Branch : out Unbounded_String) is
      Base_Id : Version.Objects.Object_Id_Storage;
      Conflicts : Version.Merge.Conflict_Vectors.Vector;
   begin
      Read_State
        (Repo          => Repo,
         Current_Id    => Current_Id,
         Target_Id     => Target_Id,
         Base_Id       => Base_Id,
         Target_Branch => Target_Branch,
         Conflicts     => Conflicts);
   end Read_State;

   procedure Clear_State (Repo : Version.Repository.Repository_Handle) is
      Path : constant String := Merge_State_Path (Repo);
   begin
      Version.Files.Delete_File_If_Exists (Path);
      Version.Files.Delete_File_If_Exists (Git_State_Path (Repo, "MERGE_HEAD"));
      Version.Files.Delete_File_If_Exists (Git_State_Path (Repo, "MERGE_MSG"));
      Version.Files.Delete_File_If_Exists (Git_State_Path (Repo, "MERGE_MODE"));
      Version.Files.Delete_File_If_Exists (Git_State_Path (Repo, "AUTO_MERGE"));
      Version.Files.Delete_File_If_Exists (Git_State_Path (Repo, "SQUASH_MSG"));
      --  A conflicted cherry-pick or revert also leaves git's own head file.
      Version.Files.Delete_File_If_Exists
        (Git_State_Path (Repo, "CHERRY_PICK_HEAD"));
      Version.Files.Delete_File_If_Exists
        (Git_State_Path (Repo, "REVERT_HEAD"));
   end Clear_State;

end Version.Merge_State;
