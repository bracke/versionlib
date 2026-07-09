with Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;

with Version.Files;
with Version.Ref_Names;

package body Version.Rebase_State is
   use Version.Objects;

   Zero_Id : constant Version.Objects.Hex_Object_Id :=
     Version.Objects.Zero_Object_Id;

   function Rebase_State_Path
     (Repo : Version.Repository.Repository_Handle) return String is
   begin
      return Version.Files.Join
        (Version.Repository.Git_Dir (Repo), "VERSION_REBASE");
   end Rebase_State_Path;

   function State_Exists
     (Repo : Version.Repository.Repository_Handle) return Boolean is
   begin
      return Version.Files.Is_Ordinary_File (Rebase_State_Path (Repo));
   end State_Exists;

   procedure Require_Id (Text : String; Field : String) is
   begin
      if not Version.Objects.Is_Valid_Hex_Object_Id (Text) then
         raise Ada.IO_Exceptions.Data_Error with
           "malformed rebase state: " & Field;
      end if;
   end Require_Id;

   procedure Require_Text (Text : String; Field : String) is
   begin
      if Text'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with
           "malformed rebase state: " & Field;
      end if;

      for C of Text loop
         if C = Character'Val (0)
           or else C = Character'Val (10)
           or else C = Character'Val (13)
         then
            raise Ada.IO_Exceptions.Data_Error with
              "malformed rebase state: " & Field;
         end if;
      end loop;
   end Require_Text;

   procedure Require_Branch_Ref (Text : String) is
      Prefix : constant String := "refs/heads/";
   begin
      Require_Text (Text, "branch");
      Version.Ref_Names.Require_Ref_Name (Text);

      if Text'Length <= Prefix'Length
        or else Text (Text'First .. Text'First + Prefix'Length - 1) /= Prefix
      then
         raise Ada.IO_Exceptions.Data_Error with
           "malformed rebase state: branch";
      end if;
   end Require_Branch_Ref;

   function After_Prefix (Line : String; Prefix : String; Field : String)
      return String is
   begin
      if Line'Length < Prefix'Length
        or else Line (Line'First .. Line'First + Prefix'Length - 1) /= Prefix
      then
         raise Ada.IO_Exceptions.Data_Error with
           "malformed rebase state: " & Field;
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
           "malformed rebase state: " & Field;
      end if;

      for C of Text loop
         if C < '0' or else C > '9' then
            raise Ada.IO_Exceptions.Data_Error with
              "malformed rebase state: " & Field;
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

   procedure Write_State
     (Repo                : Version.Repository.Repository_Handle;
      Branch_Ref          : String;
      Original_Head       : Version.Objects.Hex_Object_Id;
      Target_Head         : Version.Objects.Hex_Object_Id;
      Current_Replay_Head : Version.Objects.Hex_Object_Id;
      Next_Index          : Natural;
      Commits             : Commit_Vectors.Vector;
      Paused              : Boolean := False;
      Current_Commit      : String := "";
      Actions             : Action_Vectors.Vector := Action_Vectors.Empty_Vector;
      Execs               : Exec_Vectors.Vector := Exec_Vectors.Empty_Vector;
      Next_Exec           : Natural := 0;
      Pause_Reason        : Pause_Kind := Pause_Conflict;
      Mode                : Rebase_Mode := Mode_Linear;
      Rebased_Map         : Map_Vectors.Vector := Map_Vectors.Empty_Vector)
   is
      Content : Unbounded_String;
      Path    : constant String := Rebase_State_Path (Repo);

      function Action_Word (A : Rebase_Action) return String is
        (case A is when Pick => "pick", when Reword => "reword",
                   when Edit => "edit");

      function Action_At (I : Natural) return Rebase_Action is
        (if Actions.Is_Empty then Pick else Actions.Element (I));

      function Kind_Word (K : Pause_Kind) return String is
        (case K is when Pause_Conflict => "conflict",
                   when Pause_Edit => "edit", when Pause_Exec => "exec");
   begin
      Require_Branch_Ref (Branch_Ref);
      Require_Id (To_String (Original_Head), "original head");
      Require_Id (To_String (Target_Head), "target head");
      Require_Id (To_String (Current_Replay_Head), "current replay head");

      if Paused and then Pause_Reason /= Pause_Exec then
         Require_Id (Current_Commit, "current commit");
      elsif (not Paused or else Pause_Reason = Pause_Exec)
        and then Current_Commit'Length /= 0
      then
         raise Ada.IO_Exceptions.Data_Error with
           "malformed rebase state: current commit without commit-anchored pause";
      end if;

      if not Commits.Is_Empty then
         for I in Commits.First_Index .. Commits.Last_Index loop
            Require_Id (To_String (Commits.Element (I)), "commit");
         end loop;
      end if;

      if not Actions.Is_Empty
        and then Natural (Actions.Length) /= Natural (Commits.Length)
      then
         raise Ada.IO_Exceptions.Data_Error with
           "malformed rebase state: action count";
      end if;

      if Next_Index > Natural (Commits.Length) then
         raise Ada.IO_Exceptions.Data_Error with
           "malformed rebase state: next index";
      end if;

      if not Execs.Is_Empty then
         for I in Execs.First_Index .. Execs.Last_Index loop
            if Execs.Element (I).After > Natural (Commits.Length) then
               raise Ada.IO_Exceptions.Data_Error with
                 "malformed rebase state: exec position";
            end if;
            Require_Text (To_String (Execs.Element (I).Command), "exec command");
         end loop;
      end if;

      if Next_Exec > Natural (Execs.Length) then
         raise Ada.IO_Exceptions.Data_Error with
           "malformed rebase state: next exec";
      end if;

      if Paused and then Pause_Reason /= Pause_Exec then
         if Next_Index >= Natural (Commits.Length)
           or else Commits.Element (Commits.First_Index + Next_Index)
             /= Version.Objects.To_Object_Id (Current_Commit)
         then
            raise Ada.IO_Exceptions.Data_Error with
              "malformed rebase state: current commit";
         end if;
      end if;

      if Paused and then Pause_Reason = Pause_Exec
        and then Next_Exec >= Natural (Execs.Length)
      then
         raise Ada.IO_Exceptions.Data_Error with
           "malformed rebase state: exec pause without exec";
      end if;

      Content := To_Unbounded_String
        ("version 1" & Character'Val (10)
         & "branch " & Branch_Ref & Character'Val (10)
         & "original_head " & To_String (Original_Head) & Character'Val (10)
         & "target_head " & To_String (Target_Head) & Character'Val (10)
         & "current_replay_head " & To_String (Current_Replay_Head) & Character'Val (10)
         & "next_index " & Natural_Image (Next_Index) & Character'Val (10)
         & "total_commits " & Natural_Image (Natural (Commits.Length)) & Character'Val (10));

      if not Commits.Is_Empty then
         for I in Commits.First_Index .. Commits.Last_Index loop
            Append
              (Content,
               "commit " & To_String (Commits.Element (I))
               & " " & Action_Word (Action_At (I)) & Character'Val (10));
         end loop;
      end if;

      Append (Content, "total_execs " & Natural_Image (Natural (Execs.Length))
              & Character'Val (10));
      if not Execs.Is_Empty then
         for I in Execs.First_Index .. Execs.Last_Index loop
            Append
              (Content,
               "exec " & Natural_Image (Execs.Element (I).After) & " "
               & To_String (Execs.Element (I).Command) & Character'Val (10));
         end loop;
      end if;
      Append (Content, "next_exec " & Natural_Image (Next_Exec) & Character'Val (10));

      Append (Content,
              "mode " & (case Mode is
                            when Mode_Linear => "linear",
                            when Mode_Merges => "merges")
              & Character'Val (10));
      Append (Content, "total_map " & Natural_Image (Natural (Rebased_Map.Length))
              & Character'Val (10));
      for I in Rebased_Map.First_Index .. Rebased_Map.Last_Index loop
         Append
           (Content,
            "map " & To_String (Rebased_Map.Element (I).Original)
            & " " & To_String (Rebased_Map.Element (I).Rebased)
            & Character'Val (10));
      end loop;

      Append (Content, "paused " & (if Paused then "yes" else "no") & Character'Val (10));
      if Paused then
         Append (Content, "pause_kind " & Kind_Word (Pause_Reason) & Character'Val (10));
         if Pause_Reason /= Pause_Exec then
            Append (Content, "current_commit " & Current_Commit & Character'Val (10));
         end if;
      end if;

      Version.Files.Write_Binary_File_Atomic (Path => Path, Content => To_String (Content));
   end Write_State;

   function Read_State
     (Repo : Version.Repository.Repository_Handle)
      return Rebase_State
   is
      Path  : constant String := Rebase_State_Path (Repo);
      File  : Ada.Text_IO.File_Type;
      State : Rebase_State;
      Total : Natural;
   begin
      if not Ada.Directories.Exists (Path) then
         raise Ada.IO_Exceptions.Data_Error with "no rebase in progress";
      elsif not Version.Files.Is_Ordinary_File (Path) then
         raise Ada.IO_Exceptions.Data_Error with
           "malformed rebase state: not a regular file";
      end if;

      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Version.Files.To_Native_Path (Path));

      declare
         Version_Line : constant String := Ada.Text_IO.Get_Line (File);
      begin
         if Version_Line /= "version 1" then
            raise Ada.IO_Exceptions.Data_Error with "malformed rebase state: version";
         end if;
      end;

      declare
         Branch_Text : constant String := After_Prefix (Ada.Text_IO.Get_Line (File), "branch ", "branch");
      begin
         Require_Branch_Ref (Branch_Text);
         State.Branch_Ref_Value := To_Unbounded_String (Branch_Text);
      end;

      State.Original_Head_Value := Id_After_Prefix (Ada.Text_IO.Get_Line (File), "original_head ", "original head");
      State.Target_Head_Value := Id_After_Prefix (Ada.Text_IO.Get_Line (File), "target_head ", "target head");
      State.Current_Replay_Head_Value :=
        Id_After_Prefix
          (Ada.Text_IO.Get_Line (File),
           "current_replay_head ",
           "current replay head");
      State.Next_Index_Value :=
        Natural_Value
          (After_Prefix
             (Ada.Text_IO.Get_Line (File), "next_index ", "next index"),
           "next index");
      Total :=
        Natural_Value
          (After_Prefix
             (Ada.Text_IO.Get_Line (File), "total_commits ", "total commits"),
           "total commits");

      for I in 1 .. Total loop
         declare
            Rest : constant String :=
              After_Prefix (Ada.Text_IO.Get_Line (File), "commit ", "commit");
            Sp   : constant Natural := Ada.Strings.Fixed.Index (Rest, " ");
            Id_Text  : constant String :=
              (if Sp = 0 then Rest else Rest (Rest'First .. Sp - 1));
            Act_Text : constant String :=
              (if Sp = 0 then "pick" else Rest (Sp + 1 .. Rest'Last));
         begin
            Require_Id (Id_Text, "commit");
            State.Commits_Value.Append (Version.Objects.To_Object_Id (Id_Text));
            if Act_Text = "pick" then
               State.Actions_Value.Append (Pick);
            elsif Act_Text = "reword" then
               State.Actions_Value.Append (Reword);
            elsif Act_Text = "edit" then
               State.Actions_Value.Append (Edit);
            else
               raise Ada.IO_Exceptions.Data_Error with
                 "malformed rebase state: commit action";
            end if;
         end;
      end loop;

      declare
         Exec_Total : constant Natural :=
           Natural_Value
             (After_Prefix
                (Ada.Text_IO.Get_Line (File), "total_execs ", "total execs"),
              "total execs");
      begin
         for I in 1 .. Exec_Total loop
            declare
               Rest : constant String :=
                 After_Prefix (Ada.Text_IO.Get_Line (File), "exec ", "exec");
               Sp   : constant Natural := Ada.Strings.Fixed.Index (Rest, " ");
            begin
               if Sp = 0 then
                  raise Ada.IO_Exceptions.Data_Error with
                    "malformed rebase state: exec";
               end if;
               State.Execs_Value.Append
                 (Exec_Step'
                    (After   =>
                       Natural_Value (Rest (Rest'First .. Sp - 1), "exec position"),
                     Command =>
                       To_Unbounded_String (Rest (Sp + 1 .. Rest'Last))));
            end;
         end loop;
      end;

      State.Next_Exec_Value :=
        Natural_Value
          (After_Prefix (Ada.Text_IO.Get_Line (File), "next_exec ", "next exec"),
           "next exec");

      declare
         Mode_Text : constant String :=
           After_Prefix (Ada.Text_IO.Get_Line (File), "mode ", "mode");
      begin
         if Mode_Text = "linear" then
            State.Mode_Value := Mode_Linear;
         elsif Mode_Text = "merges" then
            State.Mode_Value := Mode_Merges;
         else
            raise Ada.IO_Exceptions.Data_Error with "malformed rebase state: mode";
         end if;
      end;

      declare
         Total_Map : constant Natural :=
           Natural_Value
             (After_Prefix (Ada.Text_IO.Get_Line (File), "total_map ", "total map"),
              "total map");
      begin
         for I in 1 .. Total_Map loop
            declare
               Line  : constant String :=
                 After_Prefix (Ada.Text_IO.Get_Line (File), "map ", "map");
               Space : constant Natural := Ada.Strings.Fixed.Index (Line, " ");
            begin
               if Space = 0 then
                  raise Ada.IO_Exceptions.Data_Error with
                    "malformed rebase state: map pair";
               end if;
               State.Rebased_Map_Value.Append
                 (Map_Pair'
                    (Original => Version.Objects.To_Object_Id
                                   (Line (Line'First .. Space - 1)),
                     Rebased  => Version.Objects.To_Object_Id
                                   (Line (Space + 1 .. Line'Last))));
            end;
         end loop;
      end;

      declare
         Paused_Text : constant String := After_Prefix (Ada.Text_IO.Get_Line (File), "paused ", "paused");
      begin
         if Paused_Text = "yes" then
            State.Paused_Value := True;
         elsif Paused_Text = "no" then
            State.Paused_Value := False;
         else
            raise Ada.IO_Exceptions.Data_Error with "malformed rebase state: paused";
         end if;
      end;

      if State.Paused_Value then
         declare
            Kind_Text : constant String :=
              After_Prefix (Ada.Text_IO.Get_Line (File), "pause_kind ", "pause kind");
         begin
            if Kind_Text = "conflict" then
               State.Pause_Reason_Value := Pause_Conflict;
            elsif Kind_Text = "edit" then
               State.Pause_Reason_Value := Pause_Edit;
            elsif Kind_Text = "exec" then
               State.Pause_Reason_Value := Pause_Exec;
            else
               raise Ada.IO_Exceptions.Data_Error with
                 "malformed rebase state: pause kind";
            end if;
         end;
         if State.Pause_Reason_Value /= Pause_Exec then
            State.Current_Commit_Value :=
              Id_After_Prefix (Ada.Text_IO.Get_Line (File), "current_commit ", "current commit");
         else
            State.Current_Commit_Value := Zero_Id;
         end if;
      else
         State.Current_Commit_Value := Zero_Id;
      end if;

      if State.Next_Index_Value > Total then
         raise Ada.IO_Exceptions.Data_Error with "malformed rebase state: next index";
      end if;

      if State.Paused_Value and then State.Pause_Reason_Value /= Pause_Exec then
         if State.Next_Index_Value >= Total
           or else State.Commits_Value.Element
             (State.Commits_Value.First_Index + State.Next_Index_Value)
               /= State.Current_Commit_Value
         then
            raise Ada.IO_Exceptions.Data_Error with
              "malformed rebase state: current commit";
         end if;
      end if;

      if State.Paused_Value and then State.Pause_Reason_Value = Pause_Exec
        and then State.Next_Exec_Value >= Natural (State.Execs_Value.Length)
      then
         raise Ada.IO_Exceptions.Data_Error with
           "malformed rebase state: exec pause without exec";
      end if;

      if not Ada.Text_IO.End_Of_File (File) then
         raise Ada.IO_Exceptions.Data_Error with "malformed rebase state: trailing data";
      end if;

      Ada.Text_IO.Close (File);
      return State;

   exception
      when Ada.IO_Exceptions.End_Error =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         raise Ada.IO_Exceptions.Data_Error with
           "malformed rebase state: truncated";

      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         raise;
   end Read_State;

   procedure Clear_State
     (Repo : Version.Repository.Repository_Handle) is
   begin
      Version.Files.Delete_File_If_Exists (Rebase_State_Path (Repo));
   end Clear_State;

   function Branch_Ref (State : Rebase_State) return String is
   begin
      return To_String (State.Branch_Ref_Value);
   end Branch_Ref;

   function Original_Head (State : Rebase_State) return Version.Objects.Hex_Object_Id is
   begin
      return State.Original_Head_Value;
   end Original_Head;

   function Target_Head (State : Rebase_State) return Version.Objects.Hex_Object_Id is
   begin
      return State.Target_Head_Value;
   end Target_Head;

   function Current_Replay_Head (State : Rebase_State) return Version.Objects.Hex_Object_Id is
   begin
      return State.Current_Replay_Head_Value;
   end Current_Replay_Head;

   function Next_Index (State : Rebase_State) return Natural is
   begin
      return State.Next_Index_Value;
   end Next_Index;

   function Total_Commits (State : Rebase_State) return Natural is
   begin
      return Natural (State.Commits_Value.Length);
   end Total_Commits;

   function Commits (State : Rebase_State) return Commit_Vectors.Vector is
   begin
      return State.Commits_Value;
   end Commits;

   function Actions (State : Rebase_State) return Action_Vectors.Vector is
   begin
      return State.Actions_Value;
   end Actions;

   function Paused (State : Rebase_State) return Boolean is
   begin
      return State.Paused_Value;
   end Paused;

   function Current_Commit (State : Rebase_State) return Version.Objects.Hex_Object_Id is
   begin
      return State.Current_Commit_Value;
   end Current_Commit;

   function Execs (State : Rebase_State) return Exec_Vectors.Vector is
   begin
      return State.Execs_Value;
   end Execs;

   function Next_Exec (State : Rebase_State) return Natural is
   begin
      return State.Next_Exec_Value;
   end Next_Exec;

   function Pause_Reason (State : Rebase_State) return Pause_Kind is
   begin
      return State.Pause_Reason_Value;
   end Pause_Reason;

   function Mode (State : Rebase_State) return Rebase_Mode is
   begin
      return State.Mode_Value;
   end Mode;

   function Rebased_Map (State : Rebase_State) return Map_Vectors.Vector is
   begin
      return State.Rebased_Map_Value;
   end Rebased_Map;

end Version.Rebase_State;
