with Ada.IO_Exceptions;

with Version.History;
with Version.Merge;
with Version.Tree_Cache;

package body Version.Blame is

   use Ada.Strings.Unbounded;

   LF : constant Character := Character'Val (10);

   package Line_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Unbounded_String);

   type Nat_Array is array (Positive range <>) of Natural;

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
         N         : constant Natural := Natural (Final.Length);
         Assigned  : array (1 .. N) of Boolean := [others => False];
         Blamed    : array (1 .. N) of Version.Objects.Object_Id_Storage :=
           [others => Tip];
         --  Position of final line I in the file at the commit being examined
         --  (0 once the line no longer exists there).
         Pos       : Nat_Array (1 .. N);
         C         : Version.Objects.Hex_Object_Id := Tip;
         Cur_Text  : Unbounded_String :=
           To_Unbounded_String (Tip_Content);
      begin
         for I in 1 .. N loop
            Pos (I) := I;
         end loop;

         loop
            declare
               Parents : constant Version.History.Commit_Id_Vectors.Vector :=
                 Version.History.Parent_Commits (Repo, C);
            begin
               if Parents.Is_Empty then
                  for I in 1 .. N loop
                     if not Assigned (I) and then Pos (I) > 0 then
                        Blamed (I) := C;
                        Assigned (I) := True;
                     end if;
                  end loop;
                  exit;
               end if;

               declare
                  Par      : constant Version.Objects.Hex_Object_Id :=
                    Parents.First_Element;
                  Par_Text : constant String :=
                    File_Content (Repo, Par, Path);
               begin
                  declare
                     --  git's own line correspondence (see Version.Merge):
                     --  blame must follow lines exactly where git follows them.
                     A : constant Version.Merge.Line_Match_Vectors.Vector :=
                       Version.Merge.Align_Lines
                         (Current_Text => To_String (Cur_Text),
                          Parent_Text  => Par_Text);
                  begin
                     for I in 1 .. N loop
                        if not Assigned (I) and then Pos (I) > 0 then
                           if Pos (I) > Natural (A.Length)
                             or else A (Pos (I)) = 0
                           then
                              --  Line at Pos(I) was introduced by C.
                              Blamed (I) := C;
                              Assigned (I) := True;
                           else
                              Pos (I) := A (Pos (I));
                           end if;
                        end if;
                     end loop;
                  end;
                  C := Par;
                  Cur_Text := To_Unbounded_String (Par_Text);
               end;
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
