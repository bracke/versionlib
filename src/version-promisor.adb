with Ada.Directories;
with Ada.Strings.Unbounded;

with Version.Files;
with Version.Fetch;
with Version.Objects;
with Version.Repository_Format;
with Version.Unsupported;

package body Version.Promisor is

   function Join (Left, Right : String) return String
   renames Version.Files.Join;

   function Has_Promisor_Metadata
     (Repo : Version.Repository.Repository_Handle)
      return Boolean
   is
      Pack_Dir : constant String :=
        Join (Join (Version.Repository.Common_Git_Dir (Repo), "objects"), "pack");
      Search : Ada.Directories.Search_Type;
      Item   : Ada.Directories.Directory_Entry_Type;
      Opened : Boolean := False;
   begin
      if not Ada.Directories.Exists (Pack_Dir) then
         return False;
      end if;

      Ada.Directories.Start_Search
        (Search    => Search,
         Directory => Pack_Dir,
         Pattern   => "*.promisor",
         Filter    =>
           [Ada.Directories.Ordinary_File => True,
            Ada.Directories.Directory     => False,
            Ada.Directories.Special_File  => False]);

      Opened := True;

      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Item);
         Ada.Directories.End_Search (Search);
         Opened := False;
         return True;
      end loop;

      Ada.Directories.End_Search (Search);
      return False;

   exception
      when others =>
         if Opened then
            Ada.Directories.End_Search (Search);
         end if;

         raise;
   end Has_Promisor_Metadata;

   function Partial_Clone_Remote
     (Repo : Version.Repository.Repository_Handle) return String
   is
      Info : constant Version.Repository_Format.Format_Info :=
        Version.Repository_Format.Read (Version.Repository.Common_Git_Dir (Repo));
   begin
      return Ada.Strings.Unbounded.To_String (Info.Partial_Clone_Remote);
   end Partial_Clone_Remote;

   function Fetch_Promised_Object
     (Repo : Version.Repository.Repository_Handle;
      Id   : String)
      return Boolean
   is
      Remote_Name : constant String := Partial_Clone_Remote (Repo);
   begin
      if Remote_Name'Length = 0
        or else not Version.Objects.Is_Valid_Hex_Object_Id (Id)
      then
         return False;
      end if;

      Version.Fetch.Fetch_Object
        (Repo        => Repo,
         Remote_Name => Remote_Name,
         Id          => Version.Objects.To_Object_Id (Id));
      return True;
   end Fetch_Promised_Object;

   function Missing_Object_Diagnostic
     (Repo : Version.Repository.Repository_Handle;
      Id   : String)
      return String
   is
   begin
      if Has_Promisor_Metadata (Repo) then
         return Version.Unsupported.Promisor_Objects & ": " & Id;
      else
         return "object not found: " & Id;
      end if;
   end Missing_Object_Diagnostic;

end Version.Promisor;
