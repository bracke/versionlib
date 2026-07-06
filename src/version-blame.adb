with Ada.Containers.Indefinite_Ordered_Sets;
with Ada.IO_Exceptions;

with Version.History;
with Version.Tree_Cache;

package body Version.Blame is

   use Ada.Strings.Unbounded;

   LF : constant Character := Character'Val (10);

   package String_Sets is new Ada.Containers.Indefinite_Ordered_Sets (String);

   package Line_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Unbounded_String);

   --  Content of Path in the tree of Commit, or "" when absent.
   function File_Content
     (Repo   : Version.Repository.Repository_Handle;
      Commit : Version.Objects.Hex_Object_Id;
      Path   : String)
      return String
   is
      Obj   : constant Version.Objects.Git_Object :=
        Version.Objects.Read_Object (Repo, Commit);
      Cache : Version.Tree_Cache.Tree_Cache;
      Flat  : constant Version.Objects.Tree_Entry_Vectors.Vector :=
        Version.Tree_Cache.Flatten_Tree
          (Repo, Cache, Version.Objects.Commit_Tree_Id (Obj));
   begin
      for E of Flat loop
         if To_String (E.Path) = Path then
            return Version.Objects.Content
                     (Version.Objects.Read_Object (Repo, E.Id));
         end if;
      end loop;
      return "";
   end File_Content;

   procedure Split (S : String; Lines : out Line_Vectors.Vector) is
      Start : Positive := S'First;
   begin
      Lines.Clear;
      if S'Length = 0 then
         return;
      end if;
      for I in S'Range loop
         if S (I) = LF then
            Lines.Append (To_Unbounded_String (S (Start .. I - 1)));
            Start := I + 1;
         end if;
      end loop;
      if Start <= S'Last then
         Lines.Append (To_Unbounded_String (S (Start .. S'Last)));
      end if;
   end Split;

   function Line_Set (S : String) return String_Sets.Set is
      V   : Line_Vectors.Vector;
      Out_Set : String_Sets.Set;
   begin
      Split (S, V);
      for L of V loop
         Out_Set.Include (To_String (L));
      end loop;
      return Out_Set;
   end Line_Set;

   function Blame_File
     (Repo : Version.Repository.Repository_Handle;
      Tip  : Version.Objects.Hex_Object_Id;
      Path : String)
      return Blame_Vectors.Vector
   is
      Tip_Content : constant String := File_Content (Repo, Tip, Path);
      Final       : Line_Vectors.Vector;
   begin
      Split (Tip_Content, Final);
      if Final.Is_Empty then
         raise Ada.IO_Exceptions.Data_Error with
           "no such path in commit: " & Path;
      end if;

      declare
         N        : constant Natural := Natural (Final.Length);
         Assigned : array (1 .. N) of Boolean := [others => False];
         Blamed   : array (1 .. N) of Version.Objects.Object_Id_Storage :=
           [others => Tip];
         C        : Version.Objects.Hex_Object_Id := Tip;
      begin
         loop
            declare
               Parents : constant Version.History.Commit_Id_Vectors.Vector :=
                 Version.History.Parent_Commits (Repo, C);
               Has_Parent : constant Boolean := not Parents.Is_Empty;
               C_Set : constant String_Sets.Set :=
                 Line_Set (File_Content (Repo, C, Path));
               P_Set : constant String_Sets.Set :=
                 (if Has_Parent
                  then Line_Set
                         (File_Content (Repo, Parents.First_Element, Path))
                  else String_Sets.Empty_Set);
            begin
               for I in 1 .. N loop
                  if not Assigned (I)
                    and then C_Set.Contains (To_String (Final.Element (I)))
                    and then not P_Set.Contains
                                  (To_String (Final.Element (I)))
                  then
                     Blamed (I) := C;
                     Assigned (I) := True;
                  end if;
               end loop;

               exit when not Has_Parent;
               C := Parents.First_Element;
            end;
         end loop;

         return Result : Blame_Vectors.Vector do
            for I in 1 .. N loop
               Result.Append
                 (Line_Blame'
                    (Commit => Blamed (I),
                     Text   => Final.Element (I)));
            end loop;
         end return;
      end;
   end Blame_File;

end Version.Blame;
