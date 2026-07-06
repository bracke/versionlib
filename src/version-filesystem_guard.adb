with Ada.Containers;
with Ada.Directories; use Ada.Directories;
with Ada.IO_Exceptions;

with GNAT.OS_Lib;

with Version.Files;
with Version.Path_Safety;
with Version.Platform;

package body Version.Filesystem_Guard is

   use type Ada.Containers.Count_Type;

   Force_Case_Insensitive : Boolean := False;

   procedure Set_Force_Case_Insensitive
     (Enabled : Boolean)
   is
   begin
      Force_Case_Insensitive := Enabled;
   end Set_Force_Case_Insensitive;

   function Case_Insensitive return Boolean is
   begin
      return Force_Case_Insensitive
        or else Version.Platform.Is_Case_Insensitive_Default;
   end Case_Insensitive;

   procedure Append_UTF8_2
     (Result : in out Unbounded_String;
      B1     : Natural;
      B2     : Natural)
   is
   begin
      Append (Result, Character'Val (B1));
      Append (Result, Character'Val (B2));
   end Append_UTF8_2;

   procedure Append_Combining_Mark
     (Result : in out Unbounded_String;
      Mark   : Natural)
   is
   begin
      Append_UTF8_2 (Result, 16#CC#, Mark);
   end Append_Combining_Mark;

   procedure Append_Decomposition
     (Result : in out Unbounded_String;
      Base   : Character;
      Mark   : Natural)
   is
   begin
      Append (Result, Base);
      Append_Combining_Mark (Result, Mark);
   end Append_Decomposition;

   function Try_Append_Latin_1_Fold
     (Result : in out Unbounded_String;
      Lead   : Natural;
      Trail  : Natural)
      return Boolean
   is
   begin
      if Lead /= 16#C3# then
         return False;
      end if;

      case Trail is
         when 16#80# | 16#A0# =>
            Append_Decomposition (Result, 'a', 16#80#);
         when 16#81# | 16#A1# =>
            Append_Decomposition (Result, 'a', 16#81#);
         when 16#82# | 16#A2# =>
            Append_Decomposition (Result, 'a', 16#82#);
         when 16#83# | 16#A3# =>
            Append_Decomposition (Result, 'a', 16#83#);
         when 16#84# | 16#A4# =>
            Append_Decomposition (Result, 'a', 16#88#);
         when 16#85# | 16#A5# =>
            Append_Decomposition (Result, 'a', 16#8A#);
         when 16#86# | 16#A6# =>
            Append_UTF8_2 (Result, 16#C3#, 16#A6#);
         when 16#87# | 16#A7# =>
            Append_Decomposition (Result, 'c', 16#A7#);
         when 16#88# | 16#A8# =>
            Append_Decomposition (Result, 'e', 16#80#);
         when 16#89# | 16#A9# =>
            Append_Decomposition (Result, 'e', 16#81#);
         when 16#8A# | 16#AA# =>
            Append_Decomposition (Result, 'e', 16#82#);
         when 16#8B# | 16#AB# =>
            Append_Decomposition (Result, 'e', 16#88#);
         when 16#8C# | 16#AC# =>
            Append_Decomposition (Result, 'i', 16#80#);
         when 16#8D# | 16#AD# =>
            Append_Decomposition (Result, 'i', 16#81#);
         when 16#8E# | 16#AE# =>
            Append_Decomposition (Result, 'i', 16#82#);
         when 16#8F# | 16#AF# =>
            Append_Decomposition (Result, 'i', 16#88#);
         when 16#90# | 16#B0# =>
            Append_UTF8_2 (Result, 16#C3#, 16#B0#);
         when 16#91# | 16#B1# =>
            Append_Decomposition (Result, 'n', 16#83#);
         when 16#92# | 16#B2# =>
            Append_Decomposition (Result, 'o', 16#80#);
         when 16#93# | 16#B3# =>
            Append_Decomposition (Result, 'o', 16#81#);
         when 16#94# | 16#B4# =>
            Append_Decomposition (Result, 'o', 16#82#);
         when 16#95# | 16#B5# =>
            Append_Decomposition (Result, 'o', 16#83#);
         when 16#96# | 16#B6# =>
            Append_Decomposition (Result, 'o', 16#88#);
         when 16#98# | 16#B8# =>
            Append_UTF8_2 (Result, 16#C3#, 16#B8#);
         when 16#99# | 16#B9# =>
            Append_Decomposition (Result, 'u', 16#80#);
         when 16#9A# | 16#BA# =>
            Append_Decomposition (Result, 'u', 16#81#);
         when 16#9B# | 16#BB# =>
            Append_Decomposition (Result, 'u', 16#82#);
         when 16#9C# | 16#BC# =>
            Append_Decomposition (Result, 'u', 16#88#);
         when 16#9D# | 16#BD# =>
            Append_Decomposition (Result, 'y', 16#81#);
         when 16#9E# | 16#BE# =>
            Append_UTF8_2 (Result, 16#C3#, 16#BE#);
         when 16#9F# =>
            Append (Result, "ss");
         when 16#BF# =>
            Append_Decomposition (Result, 'y', 16#88#);
         when others =>
            return False;
      end case;

      return True;
   end Try_Append_Latin_1_Fold;

   function Fold_For_Collision
     (Text : String)
      return String
   is
      Result : Unbounded_String;
      I      : Natural := Text'First;
   begin
      while I <= Text'Last loop
         declare
            B : constant Natural := Character'Pos (Text (I));
         begin
            if B >= Character'Pos ('A') and then B <= Character'Pos ('Z') then
               Append
                 (Result,
                  Character'Val
                    (B - Character'Pos ('A') + Character'Pos ('a')));
               I := I + 1;
            elsif I < Text'Last
              and then Try_Append_Latin_1_Fold
                (Result,
                 Character'Pos (Text (I)),
                 Character'Pos (Text (I + 1)))
            then
               I := I + 2;
            else
               Append (Result, Text (I));
               I := I + 1;
            end if;
         end;
      end loop;

      return To_String (Result);
   end Fold_For_Collision;

   function Collision_Key
     (Path : String)
      return String
   is
      Normalized : constant String :=
        Version.Path_Safety.Normalize_Relative_Path
          (Version.Files.Normalize_Separators (Path));
   begin
      if Case_Insensitive then
         return Fold_For_Collision (Normalized);
      else
         return Normalized;
      end if;
   end Collision_Key;

   function Parent_Of
     (Path : String)
      return String
   is
      Normalized : constant String := Version.Files.Normalize_Separators (Path);
   begin
      for I in reverse Normalized'Range loop
         if Normalized (I) = '/' then
            if I = Normalized'First then
               return "";
            else
               return Normalized (Normalized'First .. I - 1);
            end if;
         end if;
      end loop;
      return "";
   end Parent_Of;

   function Starts_With
     (Text   : String;
      Prefix : String)
      return Boolean
   is
   begin
      return Text'Length >= Prefix'Length
        and then Text (Text'First .. Text'First + Prefix'Length - 1) = Prefix;
   end Starts_With;

   procedure Require_No_Collisions
     (Paths : Planned_Path_Vectors.Vector)
   is
   begin
      if Paths.Length < 2 then
         return;
      end if;

      for I in Paths.First_Index .. Paths.Last_Index loop
         declare
            A     : constant Planned_Path := Paths.Element (I);
            A_Raw : constant String := To_String (A.Path);
            A_N   : constant String :=
              Version.Path_Safety.Normalize_Relative_Path (A_Raw);
            A_Key : constant String := Collision_Key (A_N);
         begin
            for J in I + 1 .. Paths.Last_Index loop
               declare
                  B     : constant Planned_Path := Paths.Element (J);
                  B_Raw : constant String := To_String (B.Path);
                  B_N   : constant String :=
                    Version.Path_Safety.Normalize_Relative_Path (B_Raw);
                  B_Key : constant String := Collision_Key (B_N);
               begin
                  if A_N = B_N and then A.Is_Directory /= B.Is_Directory then
                     raise Ada.IO_Exceptions.Data_Error with
                       "path kind collision: " & A_N;
                  elsif A_N = B_N then
                     raise Ada.IO_Exceptions.Data_Error with
                       "path collision: duplicate path: " & A_N;
                  elsif A_Key = B_Key then
                     raise Ada.IO_Exceptions.Data_Error with
                       "cannot checkout: path case collision: "
                       & A_N & " and " & B_N;
                  end if;

                  if Starts_With (B_N, A_N & "/") and then not A.Is_Directory then
                     raise Ada.IO_Exceptions.Data_Error with
                       "file/directory conflict: " & A_N & " blocks " & B_N;
                  elsif Starts_With (A_N, B_N & "/") and then not B.Is_Directory then
                     raise Ada.IO_Exceptions.Data_Error with
                       "file/directory conflict: " & B_N & " blocks " & A_N;
                  end if;
               end;
            end loop;
         end;
      end loop;
   end Require_No_Collisions;

   procedure Require_Existing_Path_Not_Special
     (Absolute_Path : String;
      Context       : String)
   is
      Native : constant String := Version.Files.To_Native_Path (Absolute_Path);
   begin
      if GNAT.OS_Lib.Is_Symbolic_Link (Native)
        or else (Ada.Directories.Exists (Native)
                 and then Ada.Directories.Kind (Native) = Ada.Directories.Special_File)
      then
         raise Ada.IO_Exceptions.Data_Error with
           "unsafe " & Context & ": special or symbolic path: " & Absolute_Path;
      end if;
   end Require_Existing_Path_Not_Special;

   procedure Require_Parent_Components_Safe
     (Repo_Root     : String;
      Relative_Path : String)
   is
      Normalized : constant String :=
        Version.Path_Safety.Normalize_Relative_Path (Relative_Path);
      Prefix     : Unbounded_String;
   begin
      for C of Normalized loop
         if C = '/' then
            declare
               Parent_Rel : constant String := To_String (Prefix);
               Parent_Abs : constant String :=
                 Version.Files.Join (Repo_Root, Parent_Rel);
               Native     : constant String := Version.Files.To_Native_Path (Parent_Abs);
            begin
               if Parent_Rel'Length > 0 then
                  if GNAT.OS_Lib.Is_Symbolic_Link (Native) then
                     raise Ada.IO_Exceptions.Data_Error with
                       "unsafe parent path: special or symbolic path: " & Parent_Rel;
                  elsif Ada.Directories.Exists (Native) then
                     if Ada.Directories.Kind (Native) = Ada.Directories.Special_File then
                        raise Ada.IO_Exceptions.Data_Error with
                          "unsafe parent path: special or symbolic path: " & Parent_Rel;
                     elsif Ada.Directories.Kind (Native) /= Ada.Directories.Directory then
                        raise Ada.IO_Exceptions.Data_Error with
                          "file blocks planned directory: " & Parent_Rel;
                     end if;
                  end if;
               end if;
            end;
         end if;
         Append (Prefix, C);
      end loop;
   end Require_Parent_Components_Safe;

   procedure Require_Safe_Write_Target
     (Repo_Root     : String;
      Relative_Path : String;
      Is_Directory  : Boolean := False;
      Is_Symlink    : Boolean := False)
   is
      Normalized : constant String :=
        Version.Path_Safety.Normalize_Relative_Path (Relative_Path);
      Absolute_Path : constant String := Version.Files.Join (Repo_Root, Normalized);
      Native : constant String := Version.Files.To_Native_Path (Absolute_Path);
   begin
      Require_Parent_Components_Safe (Repo_Root, Normalized);
      if not (Is_Symlink and then GNAT.OS_Lib.Is_Symbolic_Link (Native)) then
         Require_Existing_Path_Not_Special (Absolute_Path, "write target");
      end if;

      if Ada.Directories.Exists (Native) then
         if Is_Directory then
            if Ada.Directories.Kind (Native) /= Ada.Directories.Directory then
               raise Ada.IO_Exceptions.Data_Error with
                 "file blocks planned directory: " & Normalized;
            end if;
         elsif Is_Symlink and then GNAT.OS_Lib.Is_Symbolic_Link (Native) then
            null;
         else
            if Ada.Directories.Kind (Native) = Ada.Directories.Directory then
               raise Ada.IO_Exceptions.Data_Error with
                 "directory blocks planned file: " & Normalized;
            elsif Ada.Directories.Kind (Native) /= Ada.Directories.Ordinary_File then
               raise Ada.IO_Exceptions.Data_Error with
                 "unsafe write target: " & Normalized;
            end if;
         end if;
      end if;
   end Require_Safe_Write_Target;

   procedure Require_Safe_Delete_Target
     (Repo_Root     : String;
      Relative_Path : String)
   is
      Normalized : constant String :=
        Version.Path_Safety.Normalize_Relative_Path (Relative_Path);
      Absolute_Path : constant String := Version.Files.Join (Repo_Root, Normalized);
      Native : constant String := Version.Files.To_Native_Path (Absolute_Path);
   begin
      Require_Parent_Components_Safe (Repo_Root, Normalized);

      --  A symbolic link at the leaf is safe to remove: unlink deletes the
      --  link itself (it does not follow it), and Git replaces tracked
      --  symlinks during checkout/merge. Parent-component symlinks are still
      --  rejected by Require_Parent_Components_Safe above.
      if GNAT.OS_Lib.Is_Symbolic_Link (Native) then
         return;
      end if;

      Require_Existing_Path_Not_Special (Absolute_Path, "delete target");

      if Ada.Directories.Exists (Native) then
         if Ada.Directories.Kind (Native) /= Ada.Directories.Ordinary_File then
            raise Ada.IO_Exceptions.Data_Error with
              "unsafe delete target: not an ordinary file: " & Normalized;
         end if;
      end if;
   end Require_Safe_Delete_Target;

   procedure Preflight_Checkout
     (Repo_Root : String;
      Paths     : Planned_Path_Vectors.Vector)
   is
   begin
      Require_No_Collisions (Paths);

      if Paths.Is_Empty then
         return;
      end if;

      for I in Paths.First_Index .. Paths.Last_Index loop
         declare
            Item       : constant Planned_Path := Paths.Element (I);
            Normalized : constant String :=
              Version.Path_Safety.Normalize_Relative_Path (To_String (Item.Path));
            Parent     : constant String := Parent_Of (Normalized);
         begin
            if Parent'Length > 0 then
               Require_Safe_Write_Target
                 (Repo_Root     => Repo_Root,
                  Relative_Path => Parent,
                  Is_Directory  => True);
            end if;

            Require_Safe_Write_Target
              (Repo_Root     => Repo_Root,
               Relative_Path => Normalized,
               Is_Directory  => Item.Is_Directory,
               Is_Symlink    => Item.Is_Symlink);
         end;
      end loop;
   end Preflight_Checkout;

end Version.Filesystem_Guard;
