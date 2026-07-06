with Ada.Containers; use Ada.Containers;
with Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;

with Version.Files;
with Version.Ref_Names;

package body Version.Cherry_Pick_State is
   use Version.Objects;

   Zero_Id : constant Version.Objects.Hex_Object_Id :=
     Version.Objects.Zero_Object_Id;

   function State_Path (Repo : Version.Repository.Repository_Handle) return String is
   begin
      return Version.Files.Join
        (Version.Repository.Git_Dir (Repo), "VERSION_CHERRY_PICK");
   end State_Path;

   function State_Exists
     (Repo : Version.Repository.Repository_Handle) return Boolean is
   begin
      return Version.Files.Is_Ordinary_File (State_Path (Repo));
   end State_Exists;

   procedure Require_Id (Text : String; Field : String) is
   begin
      if not Version.Objects.Is_Valid_Hex_Object_Id (Text) then
         raise Ada.IO_Exceptions.Data_Error with
           "malformed cherry-pick state: " & Field;
      end if;
   end Require_Id;

   procedure Require_Text (Text : String; Field : String; Allow_Empty : Boolean := False) is
   begin
      if Text'Length = 0 and then not Allow_Empty then
         raise Ada.IO_Exceptions.Data_Error with
           "malformed cherry-pick state: " & Field;
      end if;

      for C of Text loop
         if C = Character'Val (0)
           or else C = Character'Val (10)
           or else C = Character'Val (13)
         then
            raise Ada.IO_Exceptions.Data_Error with
              "malformed cherry-pick state: " & Field;
         end if;
      end loop;
   end Require_Text;

   procedure Require_Head_Ref (Kind : Head_Kind; Text : String) is
      Prefix : constant String := "refs/heads/";
   begin
      if Kind = Detached_Head then
         Require_Text (Text, "head ref", Allow_Empty => True);
         if Text'Length /= 0 then
            raise Ada.IO_Exceptions.Data_Error with
              "malformed cherry-pick state: head ref";
         end if;
      else
         Require_Text (Text, "head ref");
         Version.Ref_Names.Require_Ref_Name (Text);
         if Text'Length <= Prefix'Length
           or else Text (Text'First .. Text'First + Prefix'Length - 1) /= Prefix
         then
            raise Ada.IO_Exceptions.Data_Error with
              "malformed cherry-pick state: head ref";
         end if;
      end if;
   end Require_Head_Ref;

   function After_Prefix (Line : String; Prefix : String; Field : String)
      return String is
   begin
      if Line'Length < Prefix'Length
        or else Line (Line'First .. Line'First + Prefix'Length - 1) /= Prefix
      then
         raise Ada.IO_Exceptions.Data_Error with
           "malformed cherry-pick state: " & Field;
      end if;
      return Line (Line'First + Prefix'Length .. Line'Last);
   end After_Prefix;

   function Id_After_Prefix
     (Line : String; Prefix : String; Field : String)
      return Version.Objects.Hex_Object_Id
   is
      Text : constant String := After_Prefix (Line, Prefix, Field);
   begin
      Require_Id (Text, Field);
      return Version.Objects.To_Object_Id (Text);
   end Id_After_Prefix;

   function Natural_Value (Text : String; Field : String) return Natural is
      Value : Natural := 0;
   begin
      if Text'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with
           "malformed cherry-pick state: " & Field;
      end if;

      for C of Text loop
         if C < '0' or else C > '9' then
            raise Ada.IO_Exceptions.Data_Error with
              "malformed cherry-pick state: " & Field;
         end if;
         Value := Value * 10 + Character'Pos (C) - Character'Pos ('0');
      end loop;
      return Value;
   end Natural_Value;

   function Natural_Image (Value : Natural) return String is
      Text : constant String := Natural'Image (Value);
   begin
      return Text (Text'First + 1 .. Text'Last);
   end Natural_Image;

   function Kind_Image (Kind : Head_Kind) return String is
   begin
      case Kind is
         when Symbolic_Head => return "symbolic";
         when Detached_Head => return "detached";
      end case;
   end Kind_Image;

   function Kind_Value (Text : String) return Head_Kind is
   begin
      if Text = "symbolic" then
         return Symbolic_Head;
      elsif Text = "detached" then
         return Detached_Head;
      else
         raise Ada.IO_Exceptions.Data_Error with
           "malformed cherry-pick state: head kind";
      end if;
   end Kind_Value;

   procedure Write_State
     (Repo          : Version.Repository.Repository_Handle;
      Kind          : Head_Kind;
      Head_Ref      : String;
      Original_Head : Version.Objects.Hex_Object_Id;
      Current_Head  : Version.Objects.Hex_Object_Id;
      Next_Index    : Natural;
      Commits       : Commit_Vectors.Vector;
      Mainline      : Natural := 0;
      Paused        : Boolean := False;
      Current_Commit : String := "")
   is
      Content : Unbounded_String;
   begin
      Require_Head_Ref (Kind, Head_Ref);
      Require_Id (To_String (Original_Head), "original head");
      Require_Id (To_String (Current_Head), "current head");

      if Commits.Is_Empty then
         raise Ada.IO_Exceptions.Data_Error with
           "malformed cherry-pick state: commits";
      end if;

      for I in Commits.First_Index .. Commits.Last_Index loop
         Require_Id (To_String (Commits.Element (I)), "commit");
      end loop;

      if Next_Index > Natural (Commits.Length) then
         raise Ada.IO_Exceptions.Data_Error with
           "malformed cherry-pick state: next index";
      end if;

      if Mainline > 0 and then Mainline > 16 then
         raise Ada.IO_Exceptions.Data_Error with
           "malformed cherry-pick state: mainline";
      end if;

      if Paused then
         Require_Id (Current_Commit, "current commit");
         if Next_Index >= Natural (Commits.Length)
           or else Commits.Element (Commits.First_Index + Next_Index)
             /= Version.Objects.To_Object_Id (Current_Commit)
         then
            raise Ada.IO_Exceptions.Data_Error with
              "malformed cherry-pick state: current commit";
         end if;
      elsif Current_Commit'Length /= 0 then
         raise Ada.IO_Exceptions.Data_Error with
           "malformed cherry-pick state: current commit without pause";
      end if;

      Content := To_Unbounded_String
        ("version 1" & Character'Val (10)
         & "head_kind " & Kind_Image (Kind) & Character'Val (10)
         & "head_ref " & Head_Ref & Character'Val (10)
         & "original_head " & To_String (Original_Head) & Character'Val (10)
         & "current_head " & To_String (Current_Head) & Character'Val (10)
         & "next_index " & Natural_Image (Next_Index) & Character'Val (10)
         & "mainline " & Natural_Image (Mainline) & Character'Val (10)
         & "total_commits " & Natural_Image (Natural (Commits.Length)) & Character'Val (10));

      for I in Commits.First_Index .. Commits.Last_Index loop
         Append (Content, "commit " & To_String (Commits.Element (I)) & Character'Val (10));
      end loop;

      Append (Content, "paused " & (if Paused then "yes" else "no") & Character'Val (10));
      if Paused then
         Append (Content, "current_commit " & Current_Commit & Character'Val (10));
      end if;

      Version.Files.Write_Binary_File_Atomic (Path => State_Path (Repo), Content => To_String (Content));
   end Write_State;

   function Read_State
     (Repo : Version.Repository.Repository_Handle)
      return State
   is
      Path  : constant String := State_Path (Repo);
      File  : Ada.Text_IO.File_Type;
      S     : State;
      Total : Natural;
   begin
      if not Ada.Directories.Exists (Path) then
         raise Ada.IO_Exceptions.Data_Error with "no cherry-pick in progress";
      elsif not Version.Files.Is_Ordinary_File (Path) then
         raise Ada.IO_Exceptions.Data_Error with
           "malformed cherry-pick state: not a regular file";
      end if;

      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Version.Files.To_Native_Path (Path));

      if Ada.Text_IO.Get_Line (File) /= "version 1" then
         raise Ada.IO_Exceptions.Data_Error with "malformed cherry-pick state: version";
      end if;

      S.Kind_Value := Kind_Value
        (After_Prefix (Ada.Text_IO.Get_Line (File), "head_kind ", "head kind"));
      declare
         Ref : constant String := After_Prefix
           (Ada.Text_IO.Get_Line (File), "head_ref ", "head ref");
      begin
         Require_Head_Ref (S.Kind_Value, Ref);
         S.Head_Ref_Value := To_Unbounded_String (Ref);
      end;

      S.Original_Head_Value := Id_After_Prefix
        (Ada.Text_IO.Get_Line (File), "original_head ", "original head");
      S.Current_Head_Value := Id_After_Prefix
        (Ada.Text_IO.Get_Line (File), "current_head ", "current head");
      S.Next_Index_Value := Natural_Value
        (After_Prefix (Ada.Text_IO.Get_Line (File), "next_index ", "next index"),
         "next index");
      S.Mainline_Value := Natural_Value
        (After_Prefix (Ada.Text_IO.Get_Line (File), "mainline ", "mainline"),
         "mainline");
      Total := Natural_Value
        (After_Prefix (Ada.Text_IO.Get_Line (File), "total_commits ", "total commits"),
         "total commits");

      if Total = 0 then
         raise Ada.IO_Exceptions.Data_Error with
           "malformed cherry-pick state: commits";
      end if;

      for I in 1 .. Total loop
         S.Commits_Value.Append
           (Id_After_Prefix (Ada.Text_IO.Get_Line (File), "commit ", "commit"));
      end loop;

      declare
         Paused_Text : constant String := After_Prefix
           (Ada.Text_IO.Get_Line (File), "paused ", "paused");
      begin
         if Paused_Text = "yes" then
            S.Paused_Value := True;
         elsif Paused_Text = "no" then
            S.Paused_Value := False;
         else
            raise Ada.IO_Exceptions.Data_Error with "malformed cherry-pick state: paused";
         end if;
      end;

      if S.Paused_Value then
         S.Current_Commit_Value := Id_After_Prefix
           (Ada.Text_IO.Get_Line (File), "current_commit ", "current commit");
      else
         S.Current_Commit_Value := Zero_Id;
      end if;

      if S.Next_Index_Value > Total then
         raise Ada.IO_Exceptions.Data_Error with "malformed cherry-pick state: next index";
      end if;

      if S.Paused_Value then
         if S.Next_Index_Value >= Total
           or else S.Commits_Value.Element
             (S.Commits_Value.First_Index + S.Next_Index_Value)
               /= S.Current_Commit_Value
         then
            raise Ada.IO_Exceptions.Data_Error with
              "malformed cherry-pick state: current commit";
         end if;
      end if;

      if not Ada.Text_IO.End_Of_File (File) then
         raise Ada.IO_Exceptions.Data_Error with "malformed cherry-pick state: trailing data";
      end if;

      Ada.Text_IO.Close (File);
      return S;
   exception
      when Ada.IO_Exceptions.End_Error =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         raise Ada.IO_Exceptions.Data_Error with
           "malformed cherry-pick state: truncated";
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         raise;
   end Read_State;

   procedure Clear_State
     (Repo : Version.Repository.Repository_Handle) is
   begin
      Version.Files.Delete_File_If_Exists (State_Path (Repo));
   end Clear_State;

   function Kind (S : State) return Head_Kind is
   begin
      return S.Kind_Value;
   end Kind;

   function Head_Ref (S : State) return String is
   begin
      return To_String (S.Head_Ref_Value);
   end Head_Ref;

   function Original_Head (S : State) return Version.Objects.Hex_Object_Id is
   begin
      return S.Original_Head_Value;
   end Original_Head;

   function Current_Head (S : State) return Version.Objects.Hex_Object_Id is
   begin
      return S.Current_Head_Value;
   end Current_Head;

   function Next_Index (S : State) return Natural is
   begin
      return S.Next_Index_Value;
   end Next_Index;

   function Total_Commits (S : State) return Natural is
   begin
      return Natural (S.Commits_Value.Length);
   end Total_Commits;

   function Commits (S : State) return Commit_Vectors.Vector is
   begin
      return S.Commits_Value;
   end Commits;

   function Mainline (S : State) return Natural is
   begin
      return S.Mainline_Value;
   end Mainline;

   function Paused (S : State) return Boolean is
   begin
      return S.Paused_Value;
   end Paused;

   function Current_Commit (S : State) return Version.Objects.Hex_Object_Id is
   begin
      return S.Current_Commit_Value;
   end Current_Commit;

end Version.Cherry_Pick_State;
