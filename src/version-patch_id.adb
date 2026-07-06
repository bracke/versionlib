with Ada.Strings.Unbounded;

with Version.Diff;
with Version.Hash;

package body Version.Patch_Id is

   use Ada.Strings.Unbounded;

   LF : constant Character := Character'Val (10);

   function Of_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id)
      return String
   is
      Obj    : constant Version.Objects.Git_Object :=
        Version.Objects.Read_Object (Repo, Commit_Id);
      Parent : constant String := Version.Objects.Commit_Parent_Id (Obj);

      Diff : constant String :=
        (if Parent = ""
         then Version.Diff.Diff_Root_Commit (Repo, Commit_Id)
         else Version.Diff.Diff_Commits
                (Repo, Version.Objects.To_Object_Id (Parent), Commit_Id));

      Norm  : Unbounded_String;
      Start : Positive := Diff'First;

      procedure Add_Line (Line : String) is
      begin
         if Line'Length >= 6
           and then Line (Line'First .. Line'First + 5) = "index "
         then
            return;
         elsif Line'Length >= 5
           and then Line (Line'First .. Line'First + 4) = "diff "
         then
            return;
         elsif Line'Length >= 2
           and then Line (Line'First .. Line'First + 1) = "@@"
         then
            Append (Norm, "@@" & LF);  --  drop volatile line numbers
         else
            Append (Norm, Line & LF);
         end if;
      end Add_Line;
   begin
      for I in Diff'Range loop
         if Diff (I) = LF then
            Add_Line (Diff (Start .. I - 1));
            Start := I + 1;
         end if;
      end loop;
      if Start <= Diff'Last then
         Add_Line (Diff (Start .. Diff'Last));
      end if;

      return Version.Hash.Sha1_Hex (To_String (Norm));
   end Of_Commit;

end Version.Patch_Id;
