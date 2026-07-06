with Ada.Directories; use Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

with Version.Files;
with Version.Packed_Refs;
with Version.Refs;
with Version.Ref_Names;
with Version.Transport.Local;

package body Version.Ref_Cache is
   use Version.Objects;

   function Join (Left, Right : String) return String renames Version.Files.Join;

   procedure Load_Packed_Refs
     (Repo  : Version.Repository.Repository_Handle;
      Cache : in out Ref_Cache)
   is
   begin
      if Cache.Packed_Loaded then
         return;
      end if;

      declare
         Refs : constant Version.Packed_Refs.Packed_Ref_Vectors.Vector :=
           Version.Packed_Refs.Read_All (Repo);
      begin
         Cache.Packed_Refs.Clear;
         for Ref of Refs loop
            Cache.Packed_Refs.Include (To_String (Ref.Name), Ref.Id);
         end loop;
         Cache.Packed_Loaded := True;
      end;
   end Load_Packed_Refs;

   function Read_Loose_Ref
     (Repo : Version.Repository.Repository_Handle;
      Name : String;
      Id   : out Version.Objects.Hex_Object_Id)
      return Boolean
   is
      Ref_Path : constant String :=
        Join (Version.Repository.Common_Git_Dir (Repo), Name);
   begin
      if Ada.Directories.Exists (Ref_Path)
        and then Ada.Directories.Kind (Ref_Path) = Ada.Directories.Ordinary_File
      then
         declare
            Id_Text : constant String :=
              Ada.Strings.Fixed.Trim
                (Version.Transport.Local.Read_First_Line (Ref_Path),
                 Ada.Strings.Both);
         begin
            if not Version.Objects.Is_Valid_Hex_Object_Id (Id_Text) then
               raise Ada.IO_Exceptions.Data_Error with
                 "invalid ref object id: " & Name;
            end if;

            Id := Version.Objects.To_Object_Id (Id_Text);
            return True;
         end;
      end if;

      return False;
   end Read_Loose_Ref;

   procedure Clear (Cache : in out Ref_Cache) is
   begin
      Cache.Current_Commit_Loaded := False;
      Cache.Current_Commit := Null_Unbounded_String;
      Cache.Resolved_Refs.Clear;
      Cache.Packed_Loaded := False;
      Cache.Packed_Refs.Clear;
   end Clear;

   function Current_Commit_Id
     (Repo  : Version.Repository.Repository_Handle;
      Cache : in out Ref_Cache)
      return String
   is
      Head : constant Version.Refs.Head_Info := Version.Refs.Read_Head (Repo);
   begin
      if Cache.Current_Commit_Loaded then
         return To_String (Cache.Current_Commit);
      end if;

      if Version.Refs.Is_Detached (Head) then
         declare
            Id_Text : constant String := Version.Refs.Commit_Id (Head);
         begin
            Cache.Current_Commit := To_Unbounded_String (Id_Text);
            Cache.Current_Commit_Loaded := True;
            return Id_Text;
         end;
      end if;

      declare
         Ref_Name : constant String :=
           "refs/heads/" & Version.Refs.Branch_Name (Head);
         Id       : Version.Objects.Object_Id_Storage := Version.Objects.Zero_Object_Id;
      begin
         if Try_Resolve_Ref (Repo => Repo, Cache => Cache, Name => Ref_Name, Id => Id) then
            Cache.Current_Commit := To_Unbounded_String (To_String (Id));
         else
            Cache.Current_Commit := Null_Unbounded_String;
         end if;

         Cache.Current_Commit_Loaded := True;
         return To_String (Cache.Current_Commit);
      end;
   end Current_Commit_Id;

   function Try_Resolve_Ref
     (Repo  : Version.Repository.Repository_Handle;
      Cache : in out Ref_Cache;
      Name  : String;
      Id    : out Version.Objects.Hex_Object_Id)
      return Boolean
   is
      Pos : Ref_Maps.Cursor;
   begin
      if not Version.Ref_Names.Is_Valid_Ref_Name (Name) then
         return False;
      end if;

      Pos := Cache.Resolved_Refs.Find (Name);
      if Ref_Maps.Has_Element (Pos) then
         Id := Ref_Maps.Element (Pos);
         return True;
      end if;

      if Read_Loose_Ref (Repo, Name, Id) then
         Cache.Resolved_Refs.Include (Name, Id);
         return True;
      end if;

      Load_Packed_Refs (Repo, Cache);
      Pos := Cache.Packed_Refs.Find (Name);
      if Ref_Maps.Has_Element (Pos) then
         Id := Ref_Maps.Element (Pos);
         Cache.Resolved_Refs.Include (Name, Id);
         return True;
      end if;

      return False;
   end Try_Resolve_Ref;

   function Resolve_Ref
     (Repo  : Version.Repository.Repository_Handle;
      Cache : in out Ref_Cache;
      Name  : String)
      return Version.Objects.Hex_Object_Id
   is
      Id : Version.Objects.Object_Id_Storage := Version.Objects.Zero_Object_Id;
   begin
      if Try_Resolve_Ref (Repo => Repo, Cache => Cache, Name => Name, Id => Id) then
         return Id;
      end if;

      if not Version.Ref_Names.Is_Valid_Ref_Name (Name) then
         raise Ada.IO_Exceptions.Data_Error with "invalid ref name: " & Name;
      end if;

      raise Ada.IO_Exceptions.Data_Error with "ref does not exist: " & Name;
   end Resolve_Ref;

   function Cached_Ref_Count (Cache : Ref_Cache) return Natural is
   begin
      return Natural (Cache.Resolved_Refs.Length);
   end Cached_Ref_Count;

   function Packed_Refs_Loaded (Cache : Ref_Cache) return Boolean is
   begin
      return Cache.Packed_Loaded;
   end Packed_Refs_Loaded;

   function Cached_Packed_Ref_Count (Cache : Ref_Cache) return Natural is
   begin
      return Natural (Cache.Packed_Refs.Length);
   end Cached_Packed_Ref_Count;

end Version.Ref_Cache;
