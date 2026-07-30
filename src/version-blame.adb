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

   --  The history walk both entry points share. Final holds the lines to
   --  report; Start_Pos maps each to its position in the file at Tip, where 0
   --  means the line is not present there at all. Only the working-tree form
   --  produces a 0, and such a line is in no commit yet, so it is reported
   --  against the all-zero id without being followed anywhere.
   function Walk_History
     (Repo      : Version.Repository.Repository_Handle;
      Tip       : Version.Objects.Hex_Object_Id;
      Path      : String;
      Final     : Line_Vectors.Vector;
      Start_Pos : Nat_Array;
      Tip_Text  : String)
      return Blame_Vectors.Vector
   is
      N        : constant Natural := Natural (Final.Length);
      Assigned : array (1 .. N) of Boolean;
      Blamed   : array (1 .. N) of Version.Objects.Object_Id_Storage;
      Pos      : Nat_Array (1 .. N);
      --  The line's number in the commit it is blamed to, captured at the
      --  moment of assignment (Pos then holds that position).
      Orig     : Nat_Array (1 .. N);
      C        : Version.Objects.Hex_Object_Id := Tip;
      Cur_Text : Unbounded_String := To_Unbounded_String (Tip_Text);
   begin
      for I in 1 .. N loop
         Pos (I) := Start_Pos (Start_Pos'First + I - 1);
         Assigned (I) := Pos (I) = 0;
         Blamed (I) :=
           (if Pos (I) = 0 then Version.Objects.Zero_Object_Id else Tip);
         --  An uncommitted line keeps its working-tree line number.
         Orig (I) := (if Pos (I) = 0 then I else 0);
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
                     Orig (I) := Pos (I);
                     Assigned (I) := True;
                  end if;
               end loop;
               exit;
            end if;

            declare
               Par      : constant Version.Objects.Hex_Object_Id :=
                 Parents.First_Element;
               Par_Text : constant String := File_Content (Repo, Par, Path);
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
                           Orig (I) := Pos (I);
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
                 (Commit    => Blamed (I),
                  Text      => Final.Element (I),
                  Orig_Line => Orig (I)));
         end loop;
      end return;
   end Walk_History;

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
         N   : constant Natural := Natural (Final.Length);
         Pos : Nat_Array (1 .. N);
      begin
         --  Reporting the file exactly as Tip has it: every line is where it
         --  already is.
         for I in 1 .. N loop
            Pos (I) := I;
         end loop;

         return Walk_History (Repo, Tip, Path, Final, Pos, Tip_Content);
      end;
   end Blame_File;

   function Blame_Working_File
     (Repo         : Version.Repository.Repository_Handle;
      Tip          : Version.Objects.Hex_Object_Id;
      Path         : String;
      Working_Text : String)
      return Blame_Vectors.Vector
   is
      Tip_Content : constant String := File_Content (Repo, Tip, Path);
      Final       : Line_Vectors.Vector;
   begin
      Split (Working_Text, Final);
      if Final.Is_Empty and then Tip_Content'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with
           "no such path in commit: " & Path;
      end if;

      declare
         N : constant Natural := Natural (Final.Length);
         --  Where each working-tree line sits at Tip; 0 for one that is not
         --  committed yet.
         A : constant Version.Merge.Line_Match_Vectors.Vector :=
           Version.Merge.Align_Lines
             (Current_Text => Working_Text,
              Parent_Text  => Tip_Content);
         Pos : Nat_Array (1 .. N);
      begin
         for I in 1 .. N loop
            Pos (I) := (if I > Natural (A.Length) then 0 else A (I));
         end loop;

         return Walk_History (Repo, Tip, Path, Final, Pos, Tip_Content);
      end;
   end Blame_Working_File;

end Version.Blame;
