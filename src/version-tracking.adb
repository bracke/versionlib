with Ada.Containers.Ordered_Sets;
with Ada.IO_Exceptions;

with Version.Config;
with Version.Availability;
with Version.History;
with Version.Object_Cache;
with Version.Objects;
with Version.Refs;
with Version.Remotes;
with Version.Ref_Names;
with Version.Shallow_Cache;

package body Version.Tracking is
   use Version.Objects;

   package Object_Id_Sets is new Ada.Containers.Ordered_Sets
     (Element_Type => Version.Objects.Object_Id_Storage);

   function Branch_Section (Branch_Name : String) return String is
   begin
      return "branch """ & Branch_Name & """";
   end Branch_Section;

   function Starts_With (Value : String; Prefix : String) return Boolean is
   begin
      return Value'Length >= Prefix'Length
        and then Value (Value'First .. Value'First + Prefix'Length - 1) = Prefix;
   end Starts_With;

   function Is_Valid_Branch_Name (Name : String) return Boolean is
   begin
      return Version.Ref_Names.Is_Valid_Branch_Name (Name);
   end Is_Valid_Branch_Name;

   procedure Validate_Branch_Name (Branch_Name : String) is
   begin
      if not Is_Valid_Branch_Name (Branch_Name) then
         raise Ada.IO_Exceptions.Data_Error with
           "invalid branch name: " & Branch_Name;
      end if;
   end Validate_Branch_Name;

   procedure Require_Local_Branch
     (Repo        : Version.Repository.Repository_Handle;
      Branch_Name : String)
   is
   begin
      if not Version.Refs.Ref_Exists
        (Repo => Repo,
         Name => "refs/heads/" & Branch_Name)
      then
         raise Ada.IO_Exceptions.Data_Error with
           "branch does not exist: " & Branch_Name;
      end if;
   end Require_Local_Branch;

   function Remote_Exists (Remote_Name : String) return Boolean is
      Items : constant Version.Remotes.Remote_Vectors.Vector :=
        Version.Remotes.List_Remotes;
   begin
      if Items.Is_Empty then
         return False;
      end if;

      for I in Items.First_Index .. Items.Last_Index loop
         if To_String (Items.Element (I).Name) = Remote_Name then
            return True;
         end if;
      end loop;

      return False;
   end Remote_Exists;

   function Has_Upstream
     (Repo        : Version.Repository.Repository_Handle;
      Branch_Name : String)
      return Boolean
   is
      Entries : constant Version.Config.Config_Entry_Vectors.Vector :=
        Version.Config.Read_All (Repo);

      Section : constant String := Branch_Section (Branch_Name);

      Saw_Remote : Boolean := False;
      Saw_Merge  : Boolean := False;
   begin
      Validate_Branch_Name (Branch_Name);

      if Entries.Is_Empty then
         return False;
      end if;

      for I in Entries.First_Index .. Entries.Last_Index loop
         declare
            Item_Section : constant String := To_String (Entries.Element (I).Section);
            Item_Key     : constant String := To_String (Entries.Element (I).Key);
            Item_Value   : constant String := To_String (Entries.Element (I).Value);
         begin
            if Item_Section = Section then
               if Item_Key = "remote" and then Item_Value'Length > 0 then
                  Saw_Remote := True;
               elsif Item_Key = "merge" and then Item_Value'Length > 0 then
                  Saw_Merge := True;
               end if;
            end if;
         end;
      end loop;

      return Saw_Remote and Saw_Merge;
   end Has_Upstream;

   function Upstream
     (Repo        : Version.Repository.Repository_Handle;
      Branch_Name : String)
      return Upstream_Info
   is
      Entries : constant Version.Config.Config_Entry_Vectors.Vector :=
        Version.Config.Read_All (Repo);

      Section : constant String := Branch_Section (Branch_Name);

      Result : Upstream_Info;
   begin
      Validate_Branch_Name (Branch_Name);

      if not Entries.Is_Empty then
         for I in Entries.First_Index .. Entries.Last_Index loop
            declare
               Item_Section : constant String := To_String (Entries.Element (I).Section);
               Item_Key     : constant String := To_String (Entries.Element (I).Key);
               Item_Value   : constant String := To_String (Entries.Element (I).Value);
            begin
               if Item_Section = Section then
                  if Item_Key = "remote" then
                     Result.Remote := To_Unbounded_String (Item_Value);
                  elsif Item_Key = "merge" then
                     Result.Merge := To_Unbounded_String (Item_Value);
                  end if;
               end if;
            end;
         end loop;
      end if;

      if Length (Result.Remote) = 0 or else Length (Result.Merge) = 0 then
         raise Ada.IO_Exceptions.Data_Error with
           Version.Availability.No_Upstream_Configured (Branch_Name);
      end if;

      Version.Ref_Names.Require_Remote_Name (To_String (Result.Remote));

      if not Version.Ref_Names.Is_Valid_Ref_Name (To_String (Result.Merge))
        or else not Starts_With (To_String (Result.Merge), "refs/heads/")
      then
         raise Ada.IO_Exceptions.Data_Error with
           "malformed upstream merge ref: " & To_String (Result.Merge);
      end if;

      return Result;
   end Upstream;

   procedure Set_Upstream
     (Repo        : Version.Repository.Repository_Handle;
      Branch_Name : String;
      Remote_Name : String;
      Merge_Ref   : String)
   is
      Entries : Version.Config.Config_Entry_Vectors.Vector;
      Section : constant String := Branch_Section (Branch_Name);
   begin
      Validate_Branch_Name (Branch_Name);
      Require_Local_Branch (Repo => Repo, Branch_Name => Branch_Name);

      Version.Ref_Names.Require_Remote_Name (Remote_Name);

      if not Remote_Exists (Remote_Name) then
         raise Ada.IO_Exceptions.Data_Error with
           "remote does not exist: " & Remote_Name;
      end if;

      if not Version.Ref_Names.Is_Valid_Ref_Name (Merge_Ref)
        or else not Starts_With (Merge_Ref, "refs/heads/")
      then
         raise Ada.IO_Exceptions.Data_Error with
           "malformed upstream merge ref: " & Merge_Ref;
      end if;

      Entries.Append
        (Version.Config.Config_Entry'
           (Section => To_Unbounded_String (Section),
            Key     => To_Unbounded_String ("remote"),
            Value   => To_Unbounded_String (Remote_Name)));

      Entries.Append
        (Version.Config.Config_Entry'
           (Section => To_Unbounded_String (Section),
            Key     => To_Unbounded_String ("merge"),
            Value   => To_Unbounded_String (Merge_Ref)));

      Version.Config.Replace_Section
        (Repo    => Repo,
         Section => Section,
         Entries => Entries);
   end Set_Upstream;

   procedure Unset_Upstream
     (Repo        : Version.Repository.Repository_Handle;
      Branch_Name : String)
   is
   begin
      Validate_Branch_Name (Branch_Name);

      if not Has_Upstream (Repo => Repo, Branch_Name => Branch_Name) then
         raise Ada.IO_Exceptions.Data_Error with
           Version.Availability.No_Upstream_Configured (Branch_Name);
      end if;

      Version.Config.Remove_Section
        (Repo    => Repo,
         Section => Branch_Section (Branch_Name));
   end Unset_Upstream;

   function Remote_Tracking_Ref
     (Info : Upstream_Info)
      return String
   is
      Remote_Text : constant String := To_String (Info.Remote);
      Merge_Text  : constant String := To_String (Info.Merge);
      Prefix      : constant String := "refs/heads/";
   begin
      if Remote_Text'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with "upstream remote is empty";
      end if;

      Version.Ref_Names.Require_Remote_Name (Remote_Text);

      if not Version.Ref_Names.Is_Valid_Ref_Name (Merge_Text)
        or else not Starts_With (Merge_Text, Prefix)
      then
         raise Ada.IO_Exceptions.Data_Error with
           "malformed upstream merge ref: " & Merge_Text;
      end if;

      return "refs/remotes/" & Remote_Text & "/"
        & Merge_Text (Merge_Text'First + Prefix'Length .. Merge_Text'Last);
   end Remote_Tracking_Ref;

   function Parent_Commits
     (Repo      : Version.Repository.Repository_Handle;
      Objects   : in out Version.Object_Cache.Object_Cache;
      Shallow   : in out Version.Shallow_Cache.Shallow_Cache;
      Commit_Id : Version.Objects.Hex_Object_Id)
      return Version.History.Commit_Id_Vectors.Vector
   is
      Result : Version.History.Commit_Id_Vectors.Vector;

      Commit_Object : constant Version.Objects.Git_Object :=
        Version.Object_Cache.Read_Object
          (Repo,
           Objects,
           Commit_Id);

      Parents : constant Version.Objects.Object_Id_Vectors.Vector :=
        Version.Objects.Commit_Parent_Ids (Commit_Object);
   begin
      if Version.Shallow_Cache.Is_Boundary (Repo, Shallow, Commit_Id) then
         return Result;
      end if;

      if not Parents.Is_Empty then
         for I in Parents.First_Index .. Parents.Last_Index loop
            Result.Append (Parents.Element (I));
         end loop;
      end if;

      return Result;
   end Parent_Commits;

   function Reachable_Commits
     (Repo    : Version.Repository.Repository_Handle;
      Root_Id : Version.Objects.Hex_Object_Id)
      return Version.History.Commit_Id_Vectors.Vector
   is
      Result      : Version.History.Commit_Id_Vectors.Vector;
      Pending     : Version.History.Commit_Id_Vectors.Vector;
      Pending_Set : Object_Id_Sets.Set;
      Seen        : Object_Id_Sets.Set;
      Objects     : Version.Object_Cache.Object_Cache;
      Shallow     : Version.Shallow_Cache.Shallow_Cache;
   begin
      Pending.Append (Root_Id);
      Pending_Set.Include (Root_Id);

      while not Pending.Is_Empty loop
         declare
            Current_Id : constant Version.Objects.Hex_Object_Id :=
              Pending.First_Element;
         begin
            Pending.Delete_First;
            Pending_Set.Exclude (Current_Id);

            if not Seen.Contains (Current_Id) then
               Seen.Include (Current_Id);
               Result.Append (Current_Id);

               declare
                  Parents : constant Version.History.Commit_Id_Vectors.Vector :=
                    Parent_Commits
                      (Repo      => Repo,
                       Objects   => Objects,
                       Shallow   => Shallow,
                       Commit_Id => Current_Id);
               begin
                  if not Parents.Is_Empty then
                     for I in Parents.First_Index .. Parents.Last_Index loop
                        if not Seen.Contains (Parents.Element (I))
                          and then not Pending_Set.Contains (Parents.Element (I))
                        then
                           Pending.Append (Parents.Element (I));
                           Pending_Set.Include (Parents.Element (I));
                        end if;
                     end loop;
                  end if;
               end;
            end if;
         end;
      end loop;

      return Result;
   end Reachable_Commits;

   function Difference_Count
     (Left  : Version.History.Commit_Id_Vectors.Vector;
      Right : Version.History.Commit_Id_Vectors.Vector)
      return Natural
   is
      Count     : Natural := 0;
      Right_Set : Object_Id_Sets.Set;
   begin
      if Left.Is_Empty then
         return 0;
      end if;

      if not Right.Is_Empty then
         for I in Right.First_Index .. Right.Last_Index loop
            Right_Set.Include (Right.Element (I));
         end loop;
      end if;

      for I in Left.First_Index .. Left.Last_Index loop
         if not Right_Set.Contains (Left.Element (I)) then
            Count := Count + 1;
         end if;
      end loop;

      return Count;
   end Difference_Count;

   function Count_Ahead_Behind
     (Repo        : Version.Repository.Repository_Handle;
      Branch_Name : String)
      return Ahead_Behind
   is
      Info : constant Upstream_Info :=
        Upstream (Repo => Repo, Branch_Name => Branch_Name);

      Local_Ref : constant String := "refs/heads/" & Branch_Name;
      Remote_Ref : constant String := Remote_Tracking_Ref (Info);
   begin
      Validate_Branch_Name (Branch_Name);
      Require_Local_Branch (Repo => Repo, Branch_Name => Branch_Name);

      if not Version.Refs.Ref_Exists (Repo => Repo, Name => Remote_Ref) then
         raise Ada.IO_Exceptions.Data_Error with
           "upstream ref does not exist: " & Remote_Ref;
      end if;

      declare
         Local_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Refs.Resolve_Ref (Repo => Repo, Name => Local_Ref);

         Remote_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Refs.Resolve_Ref (Repo => Repo, Name => Remote_Ref);

         Local_Set : constant Version.History.Commit_Id_Vectors.Vector :=
           Reachable_Commits (Repo => Repo, Root_Id => Local_Id);

         Remote_Set : constant Version.History.Commit_Id_Vectors.Vector :=
           Reachable_Commits (Repo => Repo, Root_Id => Remote_Id);
      begin
         return
           (Ahead  => Difference_Count (Local_Set, Remote_Set),
            Behind => Difference_Count (Remote_Set, Local_Set));
      end;
   end Count_Ahead_Behind;

end Version.Tracking;
