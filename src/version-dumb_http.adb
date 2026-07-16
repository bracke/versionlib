with Ada.Containers.Indefinite_Hashed_Sets;
with Ada.Containers.Indefinite_Vectors;
with Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Hash;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with Version.Files;
with Version.Pack;
with Version.Transport.Http;

package body Version.Dumb_Http is

   use Ada.Strings.Unbounded;
   use type Version.Objects.Tree_Entry_Kind;

   package Id_Sets is new Ada.Containers.Indefinite_Hashed_Sets
     (Element_Type        => String,
      Hash                => Ada.Strings.Hash,
      Equivalent_Elements => "=");

   package Id_Lists is new Ada.Containers.Indefinite_Vectors
     (Index_Type   => Positive,
      Element_Type => String);

   type Collecting_Consumer is limited new Version.Transport.Http.Byte_Consumer
   with record
      Data : Unbounded_String;
   end record;

   overriding
   procedure Consume
     (Item : in out Collecting_Consumer;
      Data : Ada.Streams.Stream_Element_Array)
   is
   begin
      for I in Data'Range loop
         Append (Item.Data, Character'Val (Data (I)));
      end loop;
   end Consume;

   --  A GET that comes back empty-handed rather than raising.
   function Get
     (Url   : String;
      Found : out Boolean)
      return String
   is
      Consumer : Collecting_Consumer;
   begin
      Version.Transport.Http.Get (Url, Consumer, Found);

      if not Found then
         return "";
      end if;

      return To_String (Consumer.Data);
   end Get;

   function Ends_With_Slash (Url : String) return Boolean is
     (Url'Length > 0 and then Url (Url'Last) = '/');

   -----------
   -- Fetch --
   -----------

   procedure Fetch
     (Repo      : Version.Repository.Repository_Handle;
      Base_Url  : String;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Verbose   : Boolean := False)
   is
      Url : constant String :=
        (if Ends_With_Slash (Base_Url) then Base_Url else Base_Url & "/");

      Objects_Dir : constant String :=
        Version.Files.Join
          (Version.Repository.Common_Git_Dir (Repo), "objects");

      Pending : Id_Lists.Vector;
      Seen    : Id_Sets.Set;

      Packs_Tried : Boolean := False;

      --  The read has to sit in the statement part: an exception raised in a
      --  declaration propagates past the body's own handler.
      function Have (Id : String) return Boolean is
      begin
         declare
            Obj : constant Version.Objects.Git_Object :=
              Version.Objects.Read_Object
                (Repo, Version.Objects.To_Object_Id (Id));
            pragma Unreferenced (Obj);
         begin
            return True;
         end;
      exception
         when others =>
            return False;
      end Have;

      --  A loose object on the server is already in loose-object form: the
      --  bytes go straight to disk.
      function Fetch_Loose (Id : String) return Boolean is
         Found : Boolean;

         Path : constant String :=
           Version.Files.Join
             (Version.Files.Join (Objects_Dir, Id (Id'First .. Id'First + 1)),
              Id (Id'First + 2 .. Id'Last));

         Data : constant String :=
           Get (Url & "objects/" & Id (Id'First .. Id'First + 1) & "/"
                & Id (Id'First + 2 .. Id'Last), Found);
      begin
         if not Found or else Data'Length = 0 then
            return False;
         end if;

         Version.Files.Create_Directory_If_Missing
           (Ada.Directories.Containing_Directory (Path));
         Version.Files.Write_Binary_File (Path, Data);

         if Verbose then
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error, "got " & Id);
         end if;

         return True;
      end Fetch_Loose;

      --  Everything the server advertises in objects/info/packs, downloaded
      --  and indexed once.  A dumb server has no other way to hand over an
      --  object it keeps packed.
      procedure Fetch_Packs is
         Found : Boolean;

         List : constant String := Get (Url & "objects/info/packs", Found);

         Pos : Natural := List'First;
      begin
         Packs_Tried := True;

         if not Found then
            return;
         end if;

         while Pos <= List'Last loop
            declare
               Stop : Natural :=
                 Ada.Strings.Fixed.Index (List, "" & ASCII.LF, Pos);
               Line : constant String :=
                 List (Pos .. (if Stop = 0 then List'Last else Stop - 1));
            begin
               if Stop = 0 then
                  Stop := List'Last;
               end if;

               Pos := Stop + 1;

               --  "P pack-<hash>.pack"
               if Line'Length > 2
                 and then Line (Line'First .. Line'First + 1) = "P "
               then
                  declare
                     Name : constant String :=
                       Ada.Strings.Fixed.Trim
                         (Line (Line'First + 2 .. Line'Last),
                          Ada.Strings.Both);

                     Pack_Data : constant String :=
                       Get (Url & "objects/pack/" & Name, Found);

                     Target : constant String :=
                       Version.Files.Join
                         (Version.Files.Join (Objects_Dir, "pack"), Name);
                  begin
                     if Found and then Pack_Data'Length > 0 then
                        Version.Files.Create_Directory_If_Missing
                          (Ada.Directories.Containing_Directory (Target));
                        Version.Files.Write_Binary_File (Target, Pack_Data);

                        --  Build our own index: the server's .idx is not
                        --  needed, and this way it is one we trust.
                        Version.Pack.Index_Pack
                          (Repo, Target, Canonicalize => False);

                        if Verbose then
                           Ada.Text_IO.Put_Line
                             (Ada.Text_IO.Standard_Error, "got pack " & Name);
                        end if;
                     end if;
                  end;
               end if;
            end;
         end loop;
      end Fetch_Packs;

      procedure Want (Id : String) is
      begin
         if not Seen.Contains (Id) then
            Seen.Include (Id);
            Pending.Append (Id);
         end if;
      end Want;

   begin
      Want (Version.Objects.To_String (Commit_Id));

      while not Pending.Is_Empty loop
         declare
            Id : constant String := Pending.Last_Element;
         begin
            Pending.Delete_Last;

            if not Have (Id) then
               if not Fetch_Loose (Id) then
                  if not Packs_Tried then
                     Fetch_Packs;
                  end if;

                  if not Have (Id) then
                     raise Ada.IO_Exceptions.Data_Error
                       with "unable to get object " & Id;
                  end if;
               end if;
            end if;

            --  Now that it is here, follow what it points at.
            declare
               Obj : constant Version.Objects.Git_Object :=
                 Version.Objects.Read_Object
                   (Repo, Version.Objects.To_Object_Id (Id));
            begin
               case Version.Objects.Kind (Obj) is
                  when Version.Objects.Commit_Object =>
                     Want
                       (Version.Objects.To_String
                          (Version.Objects.Commit_Tree_Id (Obj)));

                     for P of Version.Objects.Commit_Parent_Ids (Obj) loop
                        Want (Version.Objects.To_String (P));
                     end loop;

                  when Version.Objects.Tree_Object =>
                     for E of Version.Objects.Tree_Entries
                                (Repo, Version.Objects.To_Object_Id (Id))
                     loop
                        --  A gitlink names a commit in another repository.
                        if E.Kind /= Version.Objects.Tree_Gitlink then
                           Want (Version.Objects.To_String (E.Id));
                        end if;
                     end loop;

                  when Version.Objects.Tag_Object =>
                     Want
                       (Version.Objects.To_String
                          (Version.Objects.Tag_Target_Id (Obj)));

                  when others =>
                     null;
               end case;
            end;
         end;
      end loop;
   end Fetch;

end Version.Dumb_Http;
