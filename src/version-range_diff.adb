with Version.Patch_Id;
with Version.Rebase;
with Version.Rebase_State;

package body Version.Range_Diff is
   use Version.Objects;

   use Ada.Strings.Unbounded;

   Zero_Id : constant Version.Objects.Object_Id_Storage := Version.Objects.Zero_Object_Id;

   type Info is record
      Id   : Version.Objects.Object_Id_Storage;
      Pid  : Unbounded_String;
      Subj : Unbounded_String;
   end record;

   package Info_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Info);

   function Compare
     (Repo     : Version.Repository.Repository_Handle;
      Old_Base : Version.Objects.Hex_Object_Id;
      Old_Tip  : Version.Objects.Hex_Object_Id;
      New_Base : Version.Objects.Hex_Object_Id;
      New_Tip  : Version.Objects.Hex_Object_Id)
      return Pairing_Vectors.Vector
   is
      Old_C : constant Version.Rebase_State.Commit_Vectors.Vector :=
        Version.Rebase.Commits_To_Replay (Repo, Old_Tip, Old_Base);
      New_C : constant Version.Rebase_State.Commit_Vectors.Vector :=
        Version.Rebase.Commits_To_Replay (Repo, New_Tip, New_Base);

      Old_I, New_I : Info_Vectors.Vector;

      function Build (Id : Version.Objects.Hex_Object_Id) return Info is
        (Info'
           (Id   => Id,
            Pid  => To_Unbounded_String (Version.Patch_Id.Of_Commit (Repo, Id)),
            Subj => To_Unbounded_String
                      (Version.Objects.Commit_Message_First_Line
                         (Version.Objects.Read_Object (Repo, Id)))));
   begin
      for C of Old_C loop
         Old_I.Append (Build (C));
      end loop;
      for C of New_C loop
         New_I.Append (Build (C));
      end loop;

      declare
         Old_N : constant Natural := Natural (Old_I.Length);
         New_N : constant Natural := Natural (New_I.Length);
         Old_Match : array (1 .. Old_N) of Natural := [others => 0];
         New_Match : array (1 .. New_N) of Natural := [others => 0];
         New_Stat  : array (1 .. New_N) of Pair_Status := [others => Added];
         Result    : Pairing_Vectors.Vector;
      begin
         --  Phase 1: exact patch-id matches.
         for J in 1 .. New_N loop
            for I in 1 .. Old_N loop
               if New_Match (J) = 0 and then Old_Match (I) = 0
                 and then Old_I.Element (I).Pid = New_I.Element (J).Pid
               then
                  Old_Match (I) := J;
                  New_Match (J) := I;
                  New_Stat (J) := Unchanged;
               end if;
            end loop;
         end loop;

         --  Phase 2: same subject (changed content).
         for J in 1 .. New_N loop
            if New_Match (J) = 0 then
               for I in 1 .. Old_N loop
                  if Old_Match (I) = 0
                    and then Old_I.Element (I).Subj = New_I.Element (J).Subj
                  then
                     Old_Match (I) := J;
                     New_Match (J) := I;
                     New_Stat (J) := Changed;
                     exit;
                  end if;
               end loop;
            end if;
         end loop;

         --  Emit new-range order (matched or added), then removed old commits.
         for J in 1 .. New_N loop
            if New_Match (J) /= 0 then
               Result.Append
                 (Pairing'
                    (Old_Pos => New_Match (J),
                     New_Pos => J,
                     Old_Id  => Old_I.Element (New_Match (J)).Id,
                     New_Id  => New_I.Element (J).Id,
                     Subject => New_I.Element (J).Subj,
                     Status  => New_Stat (J)));
            else
               Result.Append
                 (Pairing'
                    (Old_Pos => 0,
                     New_Pos => J,
                     Old_Id  => Zero_Id,
                     New_Id  => New_I.Element (J).Id,
                     Subject => New_I.Element (J).Subj,
                     Status  => Added));
            end if;
         end loop;

         for I in 1 .. Old_N loop
            if Old_Match (I) = 0 then
               Result.Append
                 (Pairing'
                    (Old_Pos => I,
                     New_Pos => 0,
                     Old_Id  => Old_I.Element (I).Id,
                     New_Id  => Zero_Id,
                     Subject => Old_I.Element (I).Subj,
                     Status  => Removed));
            end if;
         end loop;

         return Result;
      end;
   end Compare;

end Version.Range_Diff;
