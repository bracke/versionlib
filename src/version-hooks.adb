with Ada.Directories;
with Ada.Environment_Variables;
with Ada.IO_Exceptions;
with GNAT.OS_Lib;
with GNAT.Strings;

with Version.Files;
with Version.Platform; use Version.Platform;

package body Version.Hooks is

   use type GNAT.Strings.String_Access;
   use type GNAT.OS_Lib.Process_Id;

   function Hook_Arguments (Values : String) return Argument_Vectors.Vector is
      Result : Argument_Vectors.Vector;
   begin
      if Values'Length > 0 then
         Result.Append (To_Unbounded_String (Values));
      end if;

      return Result;
   end Hook_Arguments;

   procedure Append_Argument
     (Arguments : in out Argument_Vectors.Vector; Value : String) is
   begin
      Arguments.Append (To_Unbounded_String (Value));
   end Append_Argument;

   function Is_Allowed_Hook_Name (Name : String) return Boolean is
   begin
      return
        Name = "pre-commit"
        or else Name = "commit-msg"
        or else Name = "post-checkout"
        or else Name = "pre-push"
        or else Name = "post-commit"
        or else Name = "pre-merge-commit"
        or else Name = "post-merge"
        or else Name = "pre-rebase";
   end Is_Allowed_Hook_Name;

   function Hook_Base_Path
     (Repo : Version.Repository.Repository_Handle; Name : String) return String
   is
   begin
      return
        Version.Files.Join
          (Version.Files.Join
             (Version.Repository.Common_Git_Dir (Repo), "hooks"),
           Name);
   end Hook_Base_Path;

   function Hook_Path
     (Repo : Version.Repository.Repository_Handle; Name : String) return String
   is
      Base : constant String := Hook_Base_Path (Repo, Name);
   begin
      if Version.Platform.Current = Version.Platform.Windows_Platform
        and then not Version.Files.Is_Ordinary_File (Base)
      then
         declare
            Cmd_Path : constant String := Base & ".cmd";
            Bat_Path : constant String := Base & ".bat";
            Exe_Path : constant String := Base & ".exe";
         begin
            if Version.Files.Is_Ordinary_File (Cmd_Path) then
               return Cmd_Path;
            elsif Version.Files.Is_Ordinary_File (Bat_Path) then
               return Bat_Path;
            elsif Version.Files.Is_Ordinary_File (Exe_Path) then
               return Exe_Path;
            end if;
         end;
      end if;

      return Base;
   end Hook_Path;

   function Commit_Message_Path
     (Repo : Version.Repository.Repository_Handle) return String is
   begin
      return
        Version.Files.Join
          (Version.Repository.Git_Dir (Repo), "VERSION_COMMIT_EDITMSG");
   end Commit_Message_Path;

   function Has_Windows_Hook_Extension (Path : String) return Boolean is
      Lower : String := Path;
   begin
      for I in Lower'Range loop
         if Lower (I) in 'A' .. 'Z' then
            Lower (I) :=
              Character'Val
                (Character'Pos (Lower (I))
                 - Character'Pos ('A')
                 + Character'Pos ('a'));
         end if;
      end loop;

      return
        Lower'Length >= 4
        and then
          (Lower (Lower'Last - 3 .. Lower'Last) = ".exe"
           or else Lower (Lower'Last - 3 .. Lower'Last) = ".bat"
           or else Lower (Lower'Last - 3 .. Lower'Last) = ".cmd");
   end Has_Windows_Hook_Extension;

   function POSIX_Executable (Path : String) return Boolean is
   begin
      return
        GNAT.OS_Lib.Is_Executable_File (Version.Files.To_Native_Path (Path));
   end POSIX_Executable;

   function Hook_Is_Executable (Path : String) return Boolean is
      Native : constant String := Version.Files.To_Native_Path (Path);
   begin
      if GNAT.OS_Lib.Is_Symbolic_Link (Native) then
         return False;
      end if;

      if not Version.Files.Is_Ordinary_File (Path) then
         return False;
      end if;

      case Version.Platform.Current is
         when Version.Platform.POSIX_Platform   =>
            return POSIX_Executable (Path);

         when Version.Platform.Windows_Platform =>
            return Has_Windows_Hook_Extension (Path);

         when Version.Platform.Unknown_Platform =>
            return False;
      end case;
   exception
      when others =>
         return False;
   end Hook_Is_Executable;

   procedure Save_Env
     (Name : String; Exists : out Boolean; Value : out Unbounded_String) is
   begin
      Exists := Ada.Environment_Variables.Exists (Name);
      if Exists then
         Value := To_Unbounded_String (Ada.Environment_Variables.Value (Name));
      else
         Value := Null_Unbounded_String;
      end if;
   end Save_Env;

   procedure Restore_Env
     (Name : String; Exists : Boolean; Value : Unbounded_String) is
   begin
      if Exists then
         Ada.Environment_Variables.Set (Name, To_String (Value));
      else
         Ada.Environment_Variables.Clear (Name);
      end if;
   end Restore_Env;

   type Git_Local_Env_Variable is
     (Git_Alternate_Object_Directories,
      Git_Config,
      Git_Config_Parameters,
      Git_Config_Count,
      Git_Object_Directory,
      Git_Dir,
      Git_Work_Tree,
      Git_Implicit_Work_Tree,
      Git_Graft_File,
      Git_Index_File,
      Git_No_Replace_Objects,
      Git_Replace_Ref_Base,
      Git_Prefix,
      Git_Shallow_File,
      Git_Common_Dir);

   subtype Git_Local_Env_Name is String;

   function Git_Local_Env_Name_Of
     (Variable : Git_Local_Env_Variable) return Git_Local_Env_Name
   is
   begin
      case Variable is
         when Git_Alternate_Object_Directories =>
            return "GIT_ALTERNATE_OBJECT_DIRECTORIES";
         when Git_Config =>
            return "GIT_CONFIG";
         when Git_Config_Parameters =>
            return "GIT_CONFIG_PARAMETERS";
         when Git_Config_Count =>
            return "GIT_CONFIG_COUNT";
         when Git_Object_Directory =>
            return "GIT_OBJECT_DIRECTORY";
         when Git_Dir =>
            return "GIT_DIR";
         when Git_Work_Tree =>
            return "GIT_WORK_TREE";
         when Git_Implicit_Work_Tree =>
            return "GIT_IMPLICIT_WORK_TREE";
         when Git_Graft_File =>
            return "GIT_GRAFT_FILE";
         when Git_Index_File =>
            return "GIT_INDEX_FILE";
         when Git_No_Replace_Objects =>
            return "GIT_NO_REPLACE_OBJECTS";
         when Git_Replace_Ref_Base =>
            return "GIT_REPLACE_REF_BASE";
         when Git_Prefix =>
            return "GIT_PREFIX";
         when Git_Shallow_File =>
            return "GIT_SHALLOW_FILE";
         when Git_Common_Dir =>
            return "GIT_COMMON_DIR";
      end case;
   end Git_Local_Env_Name_Of;

   type Git_Local_Env_Exists_Array is
     array (Git_Local_Env_Variable) of Boolean;
   type Git_Local_Env_Value_Array is
     array (Git_Local_Env_Variable) of Unbounded_String;

   procedure Save_Git_Local_Env
     (Exists : out Git_Local_Env_Exists_Array;
      Values : out Git_Local_Env_Value_Array)
   is
   begin
      for Variable in Git_Local_Env_Variable loop
         Save_Env (Git_Local_Env_Name_Of (Variable),
                   Exists (Variable),
                   Values (Variable));
      end loop;
   end Save_Git_Local_Env;

   procedure Restore_Git_Local_Env
     (Exists : Git_Local_Env_Exists_Array;
      Values : Git_Local_Env_Value_Array)
   is
   begin
      for Variable in Git_Local_Env_Variable loop
         Restore_Env (Git_Local_Env_Name_Of (Variable),
                      Exists (Variable),
                      Values (Variable));
      end loop;
   end Restore_Git_Local_Env;

   procedure Prepare_Git_Local_Env
     (Repo : Version.Repository.Repository_Handle)
   is
   begin
      for Variable in Git_Local_Env_Variable loop
         Ada.Environment_Variables.Clear (Git_Local_Env_Name_Of (Variable));
      end loop;

      Ada.Environment_Variables.Set
        ("GIT_DIR", Version.Repository.Git_Dir (Repo));
      Ada.Environment_Variables.Set
        ("GIT_COMMON_DIR", Version.Repository.Common_Git_Dir (Repo));
      Ada.Environment_Variables.Set
        ("GIT_WORK_TREE", Version.Repository.Root_Path (Repo));
      Ada.Environment_Variables.Set
        ("GIT_INDEX_FILE",
         Version.Files.Join (Version.Repository.Git_Dir (Repo), "index"));
      Ada.Environment_Variables.Set ("GIT_IMPLICIT_WORK_TREE", "0");
   end Prepare_Git_Local_Env;

   function Run_Hook
     (Repo      : Version.Repository.Repository_Handle;
      Name      : String;
      Arguments : Argument_Vectors.Vector;
      Blocking  : Boolean := True) return Hook_Result
   is
      Old_Dir : constant String := Ada.Directories.Current_Directory;

      Old_Git_Local_Env_Exists : Git_Local_Env_Exists_Array :=
        [others => False];
      Old_Git_Local_Env_Values : Git_Local_Env_Value_Array;
      Old_Version_Exists       : Boolean := False;
      Old_Version              : Unbounded_String;

      Arg_Count : constant Natural := Natural (Arguments.Length);
      Args      : GNAT.OS_Lib.Argument_List (1 .. Arg_Count) :=
        [others => null];
      Status    : Integer := 0;
      Pid       : GNAT.OS_Lib.Process_Id := GNAT.OS_Lib.Invalid_Pid;
   begin
      if Hooks_Disabled then
         return
           (Ran => False, Exit_Code => 0, Output => Null_Unbounded_String);
      end if;

      if not Is_Allowed_Hook_Name (Name) then
         raise Ada.IO_Exceptions.Data_Error
           with "unsupported hook name: " & Name;
      end if;

      declare
         Path : constant String := Hook_Path (Repo, Name);
      begin
         if not Hook_Is_Executable (Path) then
            return
              (Ran => False, Exit_Code => 0, Output => Null_Unbounded_String);
         end if;

         if Arg_Count > 0 then
            for I in Arguments.First_Index .. Arguments.Last_Index loop
               Args (Positive (I - Arguments.First_Index + 1)) :=
                 new String'(To_String (Arguments.Element (I)));
            end loop;
         end if;

         Save_Git_Local_Env
           (Old_Git_Local_Env_Exists, Old_Git_Local_Env_Values);
         Save_Env ("VERSION", Old_Version_Exists, Old_Version);

         Prepare_Git_Local_Env (Repo);
         Ada.Environment_Variables.Set ("VERSION", "1");

         Ada.Directories.Set_Directory
           (Version.Files.To_Native_Path
              (Version.Repository.Root_Path (Repo)));

         if Blocking then
            Status :=
              GNAT.OS_Lib.Spawn
                (Program_Name => Version.Files.To_Native_Path (Path),
                 Args         => Args);
         else
            Pid :=
              GNAT.OS_Lib.Non_Blocking_Spawn
                (Program_Name => Version.Files.To_Native_Path (Path),
                 Args         => Args);

            if Pid = GNAT.OS_Lib.Invalid_Pid then
               Status := 1;
            else
               Status := 0;
            end if;
         end if;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Restore_Git_Local_Env
        (Old_Git_Local_Env_Exists, Old_Git_Local_Env_Values);
      Restore_Env ("VERSION", Old_Version_Exists, Old_Version);

      if Arg_Count > 0 then
         for I in Args'Range loop
            GNAT.OS_Lib.Free (Args (I));
         end loop;
      end if;

      return
        (Ran => True, Exit_Code => Status, Output => Null_Unbounded_String);

   exception
      when others =>
         if Ada.Directories.Current_Directory /= Old_Dir then
            Ada.Directories.Set_Directory (Old_Dir);
         end if;

         Restore_Git_Local_Env
           (Old_Git_Local_Env_Exists, Old_Git_Local_Env_Values);
         Restore_Env ("VERSION", Old_Version_Exists, Old_Version);

         if Arg_Count > 0 then
            for I in Args'Range loop
               if Args (I) /= null then
                  GNAT.OS_Lib.Free (Args (I));
               end if;
            end loop;
         end if;

         raise;
   end Run_Hook;

   function Prepare_Commit_Message
     (Repo      : Version.Repository.Repository_Handle;
      Message   : String;
      Run_Hooks : Boolean := True) return String
   is
      Args : Argument_Vectors.Vector;
      Path : constant String := Commit_Message_Path (Repo);
   begin
      if not Run_Hooks then
         return Message;
      end if;

      Require_Hook_Success
        (Run_Hook
           (Repo      => Repo,
            Name      => "pre-commit",
            Arguments => Args,
            Blocking  => True),
         "pre-commit");

      Version.Files.Write_Binary_File (Path => Path, Content => Message);
      Append_Argument (Args, Path);

      Require_Hook_Success
        (Run_Hook
           (Repo      => Repo,
            Name      => "commit-msg",
            Arguments => Args,
            Blocking  => True),
         "commit-msg");

      return Version.Files.Read_Binary_File (Path);
   end Prepare_Commit_Message;

   procedure Run_Post_Commit
     (Repo : Version.Repository.Repository_Handle; Run_Hooks : Boolean := True)
   is
      Args   : Argument_Vectors.Vector;
      Result : Hook_Result;
   begin
      if Run_Hooks then
         Result :=
           Run_Hook
             (Repo      => Repo,
              Name      => "post-commit",
              Arguments => Args,
              Blocking  => True);
         Require_Hook_Success (Result, "post-commit");
      end if;
   end Run_Post_Commit;

   procedure Run_Pre_Merge_Commit
     (Repo : Version.Repository.Repository_Handle; Run_Hooks : Boolean := True)
   is
      Args   : Argument_Vectors.Vector;
      Result : Hook_Result;
   begin
      if Run_Hooks then
         Result :=
           Run_Hook
             (Repo      => Repo,
              Name      => "pre-merge-commit",
              Arguments => Args,
              Blocking  => True);
         Require_Hook_Success (Result, "pre-merge-commit");
      end if;
   end Run_Pre_Merge_Commit;

   procedure Run_Post_Merge
     (Repo      : Version.Repository.Repository_Handle;
      Squash    : Boolean := False;
      Run_Hooks : Boolean := True)
   is
      Args   : Argument_Vectors.Vector;
      Result : Hook_Result;
   begin
      if Run_Hooks then
         Append_Argument (Args, (if Squash then "1" else "0"));
         Result :=
           Run_Hook
             (Repo      => Repo,
              Name      => "post-merge",
              Arguments => Args,
              Blocking  => True);
         Require_Hook_Success (Result, "post-merge");
      end if;
   end Run_Post_Merge;

   procedure Run_Post_Checkout
     (Repo      : Version.Repository.Repository_Handle;
      Old_Id    : String;
      New_Id    : String;
      Flag      : String;
      Run_Hooks : Boolean := True)
   is
      Args   : Argument_Vectors.Vector;
      Result : Hook_Result;
   begin
      if Run_Hooks then
         Append_Argument (Args, Old_Id);
         Append_Argument (Args, New_Id);
         Append_Argument (Args, Flag);
         Result :=
           Run_Hook
             (Repo      => Repo,
              Name      => "post-checkout",
              Arguments => Args,
              Blocking  => True);
         pragma Unreferenced (Result);
      end if;
   end Run_Post_Checkout;

   procedure Require_Hook_Success (Result : Hook_Result; Context : String) is
   begin
      if Result.Ran and then Result.Exit_Code /= 0 then
         raise Ada.IO_Exceptions.Data_Error
           with
             Context
             & " hook failed with exit code"
             & Integer'Image (Result.Exit_Code);
      end if;
   end Require_Hook_Success;

   function Hooks_Disabled return Boolean is
   begin
      return
        Ada.Environment_Variables.Exists ("VERSION_NO_HOOKS")
        and then Ada.Environment_Variables.Value ("VERSION_NO_HOOKS") = "1";
   exception
      when others =>
         return False;
   end Hooks_Disabled;

end Version.Hooks;
