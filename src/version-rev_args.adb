with Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;

with Version.Files;
with Version.Objects;
with Version.Ref_Format;
with Version.Revisions;

package body Version.Rev_Args is

   function Ref_Tips
     (Repo   : Version.Repository.Repository_Handle;
      Prefix : String := "")
      return Version.History.Commit_Id_Vectors.Vector
   is
      Patterns : Version.Ref_Format.String_Vectors.Vector;
      Result   : Version.History.Commit_Id_Vectors.Vector;
   begin
      if Prefix /= "" then
         Patterns.Append (Prefix);
      end if;

      for Ref of Version.Ref_Format.For_Each_Ref
        (Repo, Patterns, Format => "%(refname)")
      loop
         begin
            Result.Append (Version.Revisions.Resolve_Commit (Repo, Ref));
         exception
            when others =>
               --  A ref that does not peel to a commit (a tag on a blob, say)
               --  contributes nothing to a commit walk.
               null;
         end;
      end loop;

      return Result;
   end Ref_Tips;

   function Looks_Like_Path
     (Repo : Version.Repository.Repository_Handle;
      Text : String)
      return Boolean
   is
   begin
      --  git accepts an operand as a path when it names something on disk;
      --  anything else is a revision that failed to resolve.
      return Ada.Directories.Exists
        (Version.Files.Join (Version.Repository.Root_Path (Repo), Text));
   exception
      when others =>
         return False;
   end Looks_Like_Path;

   function Parse
     (Repo : Version.Repository.Repository_Handle;
      Args : String_Vectors.Vector)
      return Revision_Arguments
   is
      Result     : Revision_Arguments;
      Only_Paths : Boolean := False;

      procedure Add_Range (Left, Right : String; Symmetric : Boolean) is
         Left_Id  : constant Version.Objects.Hex_Object_Id :=
           Version.Revisions.Resolve_Commit
             (Repo, (if Left = "" then "HEAD" else Left));
         Right_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Revisions.Resolve_Commit
             (Repo, (if Right = "" then "HEAD" else Right));
      begin
         if Symmetric then
            --  A...B: everything reachable from either side but not from
            --  both, so both tips are included and their bases excluded.
            Result.Include.Append (Left_Id);
            Result.Include.Append (Right_Id);

            for Base of Version.History.Merge_Bases (Repo, Left_Id, Right_Id)
            loop
               Result.Exclude.Append (Base);
            end loop;
         else
            Result.Exclude.Append (Left_Id);
            Result.Include.Append (Right_Id);
         end if;

         Result.Saw_Revision := True;
      end Add_Range;
   begin
      for Arg of Args loop
         if Only_Paths then
            Result.Paths.Append (Arg);

         elsif Arg = "--" then
            Only_Paths := True;

         elsif Arg'Length > 1 and then Arg (Arg'First) = '^' then
            Result.Exclude.Append
              (Version.Revisions.Resolve_Commit
                 (Repo, Arg (Arg'First + 1 .. Arg'Last)));
            Result.Saw_Revision := True;

         elsif Ada.Strings.Fixed.Index (Arg, "...") > 0 then
            declare
               Sep : constant Natural := Ada.Strings.Fixed.Index (Arg, "...");
            begin
               Add_Range
                 (Arg (Arg'First .. Sep - 1),
                  Arg (Sep + 3 .. Arg'Last),
                  Symmetric => True);
            end;

         elsif Ada.Strings.Fixed.Index (Arg, "..") > 0 then
            declare
               Sep : constant Natural := Ada.Strings.Fixed.Index (Arg, "..");
            begin
               Add_Range
                 (Arg (Arg'First .. Sep - 1),
                  Arg (Sep + 2 .. Arg'Last),
                  Symmetric => False);
            end;

         else
            begin
               Result.Include.Append
                 (Version.Revisions.Resolve_Commit (Repo, Arg));
               Result.Saw_Revision := True;
            exception
               when others =>
                  --  Not a revision. git falls back to reading it as a path,
                  --  but only if it actually names one.
                  if Looks_Like_Path (Repo, Arg) then
                     Only_Paths := True;
                     Result.Paths.Append (Arg);
                  else
                     raise Ada.IO_Exceptions.Data_Error
                       with "ambiguous argument '" & Arg
                            & "': unknown revision or path not in the "
                            & "working tree.";
                  end if;
            end;
         end if;
      end loop;

      return Result;
   end Parse;

end Version.Rev_Args;
