with Ada.Strings.Unbounded;

package body Version.Log_Graph is

   use Ada.Strings.Unbounded;
   use type Version.Objects.Hex_Object_Id;

   Merge_Chars : constant array (0 .. 2) of Character := ('/', '|', '\');

   ----------
   -- Init --
   ----------

   procedure Init (G : out Graph) is
   begin
      G.Have_Commit := False;
      G.Num_Parents := 0;
      G.Width := 0;
      G.Expansion_Row := 0;
      G.State := S_Padding;
      G.Prev_State := S_Padding;
      G.Commit_Index := 0;
      G.Prev_Commit_Index := 0;
      G.Merge_Layout := 0;
      G.Edges_Added := 0;
      G.Prev_Edges_Added := 0;
      G.Num_Columns := 0;
      G.Num_New_Columns := 0;
      G.Mapping_Size := 0;
      G.Mapping := [others => -1];
      G.Old_Mapping := [others => -1];
      G.Parents.Clear;
   end Init;

   ------------------
   -- Update_State --
   ------------------

   procedure Update_State (G : in out Graph; S : State_Kind) is
   begin
      G.Prev_State := G.State;
      G.State := S;
   end Update_State;

   ----------
   -- Pad --
   ----------

   --  Pad the line out to the graph width so text to its right stays aligned.
   procedure Pad (G : Graph; Line : in out Unbounded_String) is
   begin
      if Length (Line) < G.Width then
         Append (Line, [1 .. G.Width - Length (Line) => ' ']);
      end if;
   end Pad;

   ---------------------------------
   -- Find_New_Column_By_Commit --
   ---------------------------------

   function Find_New_Column_By_Commit
     (G : Graph; Commit : Version.Objects.Hex_Object_Id) return Integer is
   begin
      for I in 0 .. G.Num_New_Columns - 1 loop
         if G.New_Columns (I) = Commit then
            return I;
         end if;
      end loop;
      return -1;
   end Find_New_Column_By_Commit;

   -------------------------------
   -- Insert_Into_New_Columns --
   -------------------------------

   procedure Insert_Into_New_Columns
     (G      : in out Graph;
      Commit : Version.Objects.Hex_Object_Id;
      Idx    : Integer)
   is
      I           : Integer := Find_New_Column_By_Commit (G, Commit);
      Mapping_Idx : Integer;
   begin
      --  Add the commit to new_columns if it is not there yet.
      if I < 0 then
         I := G.Num_New_Columns;
         G.Num_New_Columns := G.Num_New_Columns + 1;
         G.New_Columns (I) := Commit;
      end if;

      if G.Num_Parents > 1 and then Idx > -1 and then G.Merge_Layout = -1 then
         --  First parent of a merge: pick a layout based on whether the parent
         --  is in a column to the left of the merge.
         declare
            Dist  : constant Integer := Idx - I;
            Shift : constant Integer := (if Dist > 1 then 2 * Dist - 3 else 1);
         begin
            G.Merge_Layout := (if Dist > 0 then 0 else 1);
            G.Edges_Added := G.Num_Parents + G.Merge_Layout - 2;
            Mapping_Idx := G.Width + (G.Merge_Layout - 1) * Shift;
            G.Width := G.Width + 2 * G.Merge_Layout;
         end;
      elsif G.Edges_Added > 0
        and then I = G.Mapping (G.Width - 2)
      then
         --  Merge added columns but this commit is in the last existing
         --  column: join the two edges immediately.
         Mapping_Idx := G.Width - 2;
         G.Edges_Added := -1;
      else
         Mapping_Idx := G.Width;
         G.Width := G.Width + 2;
      end if;

      G.Mapping (Mapping_Idx) := I;
   end Insert_Into_New_Columns;

   --------------------------
   -- Update_Columns --
   --------------------------

   procedure Update_Columns (G : in out Graph) is
      Tmp                 : Id_Array;
      Max_New_Columns     : Integer;
      Seen_This           : Boolean := False;
      Col_Commit          : Version.Objects.Hex_Object_Id;
   begin
      --  Swap columns and new_columns: columns now holds this commit's state,
      --  new_columns is reused to compute the following commit's state.
      Tmp := G.Columns;
      G.Columns := G.New_Columns;
      G.New_Columns := Tmp;
      G.Num_Columns := G.Num_New_Columns;
      G.Num_New_Columns := 0;

      Max_New_Columns := G.Num_Columns + G.Num_Parents;

      G.Mapping_Size := 2 * Max_New_Columns;
      for I in 0 .. G.Mapping_Size - 1 loop
         G.Mapping (I) := -1;
      end loop;

      G.Width := 0;
      G.Prev_Edges_Added := G.Edges_Added;
      G.Edges_Added := 0;

      for I in 0 .. G.Num_Columns loop
         if I = G.Num_Columns then
            if Seen_This then
               exit;
            end if;
            Col_Commit := G.Commit;
         else
            Col_Commit := G.Columns (I);
         end if;

         if Col_Commit = G.Commit then
            Seen_This := True;
            G.Commit_Index := I;
            G.Merge_Layout := -1;
            for P of G.Parents loop
               Insert_Into_New_Columns (G, P, I);
            end loop;
            --  The current commit always takes up at least 2 columns.
            if G.Num_Parents = 0 then
               G.Width := G.Width + 2;
            end if;
         else
            Insert_Into_New_Columns (G, Col_Commit, -1);
         end if;
      end loop;

      --  Shrink mapping_size to the minimum necessary.
      while G.Mapping_Size > 1
        and then G.Mapping (G.Mapping_Size - 1) < 0
      loop
         G.Mapping_Size := G.Mapping_Size - 1;
      end loop;
   end Update_Columns;

   -------------------------------
   -- Num_Dashed_Parents --
   -------------------------------

   function Num_Dashed_Parents (G : Graph) return Integer is
     (G.Num_Parents + G.Merge_Layout - 3);

   function Num_Expansion_Rows (G : Graph) return Integer is
     (Num_Dashed_Parents (G) * 2);

   function Needs_Pre_Commit_Line (G : Graph) return Boolean is
     (G.Num_Parents >= 3
      and then G.Commit_Index < G.Num_Columns - 1
      and then G.Expansion_Row < Num_Expansion_Rows (G));

   ------------------
   -- Do_Update --
   ------------------

   procedure Do_Update
     (G       : in out Graph;
      Commit  : Version.Objects.Hex_Object_Id;
      Parents : Version.Objects.Object_Id_Vectors.Vector)
   is
   begin
      G.Commit := Commit;
      G.Have_Commit := True;
      G.Parents := Parents;
      G.Num_Parents := Integer (Parents.Length);

      G.Prev_Commit_Index := G.Commit_Index;
      Update_Columns (G);
      G.Expansion_Row := 0;

      --  Set state directly (not via Update_State) so prev_state keeps the
      --  state of the previous commit's last output line.
      if G.State /= S_Padding then
         G.State := S_Skip;
      elsif Needs_Pre_Commit_Line (G) then
         G.State := S_Pre_Commit;
      else
         G.State := S_Commit;
      end if;
   end Do_Update;

   -------------------------
   -- Is_Mapping_Correct --
   -------------------------

   function Is_Mapping_Correct (G : Graph) return Boolean is
   begin
      for I in 0 .. G.Mapping_Size - 1 loop
         declare
            Target : constant Integer := G.Mapping (I);
         begin
            if Target < 0 then
               null;
            elsif Target = I / 2 then
               null;
            else
               return False;
            end if;
         end;
      end loop;
      return True;
   end Is_Mapping_Correct;

   --------------------------
   -- Output_Padding_Line --
   --------------------------

   procedure Output_Padding_Line (G : Graph; Line : in out Unbounded_String) is
   begin
      for I in 0 .. G.Num_New_Columns - 1 loop
         Append (Line, '|');
         Append (Line, ' ');
      end loop;
   end Output_Padding_Line;

   ------------------------
   -- Output_Skip_Line --
   ------------------------

   procedure Output_Skip_Line (G : in out Graph; Line : in out Unbounded_String)
   is
   begin
      Append (Line, "...");
      if Needs_Pre_Commit_Line (G) then
         Update_State (G, S_Pre_Commit);
      else
         Update_State (G, S_Commit);
      end if;
   end Output_Skip_Line;

   ------------------------------
   -- Output_Pre_Commit_Line --
   ------------------------------

   procedure Output_Pre_Commit_Line
     (G : in out Graph; Line : in out Unbounded_String)
   is
      Seen_This : Boolean := False;
   begin
      for I in 0 .. G.Num_Columns - 1 loop
         if G.Columns (I) = G.Commit then
            Seen_This := True;
            Append (Line, '|');
            Append (Line, [1 .. G.Expansion_Row => ' ']);
         elsif Seen_This and then G.Expansion_Row = 0 then
            if G.Prev_State = S_Post_Merge
              and then G.Prev_Commit_Index < I
            then
               Append (Line, '\');
            else
               Append (Line, '|');
            end if;
         elsif Seen_This and then G.Expansion_Row > 0 then
            Append (Line, '\');
         else
            Append (Line, '|');
         end if;
         Append (Line, ' ');
      end loop;

      G.Expansion_Row := G.Expansion_Row + 1;
      if not Needs_Pre_Commit_Line (G) then
         Update_State (G, S_Commit);
      end if;
   end Output_Pre_Commit_Line;

   -----------------------------
   -- Draw_Octopus_Merge --
   -----------------------------

   procedure Draw_Octopus_Merge (G : Graph; Line : in out Unbounded_String) is
      Dashed_Parents : constant Integer := Num_Dashed_Parents (G);
   begin
      for I in 0 .. Dashed_Parents - 1 loop
         Append (Line, '-');
         Append (Line, (if I = Dashed_Parents - 1 then '.' else '-'));
      end loop;
   end Draw_Octopus_Merge;

   --------------------------
   -- Output_Commit_Line --
   --------------------------

   procedure Output_Commit_Line
     (G : in out Graph; Line : in out Unbounded_String)
   is
      Seen_This  : Boolean := False;
      Col_Commit : Version.Objects.Hex_Object_Id;
   begin
      for I in 0 .. G.Num_Columns loop
         if I = G.Num_Columns then
            if Seen_This then
               exit;
            end if;
            Col_Commit := G.Commit;
         else
            Col_Commit := G.Columns (I);
         end if;

         if Col_Commit = G.Commit then
            Seen_This := True;
            Append (Line, '*');
            if G.Num_Parents > 2 then
               Draw_Octopus_Merge (G, Line);
            end if;
         elsif Seen_This and then G.Edges_Added > 1 then
            Append (Line, '\');
         elsif Seen_This and then G.Edges_Added = 1 then
            if G.Prev_State = S_Post_Merge
              and then G.Prev_Edges_Added > 0
              and then G.Prev_Commit_Index < I
            then
               Append (Line, '\');
            else
               Append (Line, '|');
            end if;
         elsif G.Prev_State = S_Collapsing
           and then G.Old_Mapping (2 * I + 1) = I
           and then G.Mapping (2 * I) < I
         then
            Append (Line, '/');
         else
            Append (Line, '|');
         end if;
         Append (Line, ' ');
      end loop;

      --  Update state (truncation is not modelled, so a merge always draws a
      --  post-merge line).
      if G.Num_Parents > 1 then
         Update_State (G, S_Post_Merge);
      elsif Is_Mapping_Correct (G) then
         Update_State (G, S_Padding);
      else
         Update_State (G, S_Collapsing);
      end if;
   end Output_Commit_Line;

   ------------------------------
   -- Output_Post_Merge_Line --
   ------------------------------

   procedure Output_Post_Merge_Line
     (G : in out Graph; Line : in out Unbounded_String)
   is
      Seen_This      : Boolean := False;
      Col_Commit     : Version.Objects.Hex_Object_Id;
      First_Parent   : constant Version.Objects.Hex_Object_Id :=
        G.Parents.First_Element;
      Parent_Col_Set : Boolean := False;
   begin
      for I in 0 .. G.Num_Columns loop
         if I = G.Num_Columns then
            if Seen_This then
               exit;
            end if;
            Col_Commit := G.Commit;
         else
            Col_Commit := G.Columns (I);
         end if;

         if Col_Commit = G.Commit then
            --  Draw the merge's parent edges from new_columns.
            declare
               Idx : Integer := G.Merge_Layout;
            begin
               Seen_This := True;
               for J in 0 .. G.Num_Parents - 1 loop
                  Append (Line, Merge_Chars (Idx));

                  if Idx = 2 then
                     if G.Edges_Added > 0 or else J < G.Num_Parents - 1 then
                        Append (Line, ' ');
                     end if;
                  else
                     Idx := Idx + 1;
                  end if;
               end loop;
               if G.Edges_Added = 0 then
                  Append (Line, ' ');
               end if;
            end;
         elsif Seen_This then
            if G.Edges_Added > 0 then
               Append (Line, '\');
            else
               Append (Line, '|');
            end if;
            Append (Line, ' ');
         else
            Append (Line, '|');
            if G.Merge_Layout /= 0 or else I /= G.Commit_Index - 1 then
               if Parent_Col_Set then
                  Append (Line, '_');
               else
                  Append (Line, ' ');
               end if;
            end if;
         end if;

         if Col_Commit = First_Parent then
            Parent_Col_Set := True;
         end if;
      end loop;

      if Is_Mapping_Correct (G) then
         Update_State (G, S_Padding);
      else
         Update_State (G, S_Collapsing);
      end if;
   end Output_Post_Merge_Line;

   ------------------------------
   -- Output_Collapsing_Line --
   ------------------------------

   procedure Output_Collapsing_Line
     (G : in out Graph; Line : in out Unbounded_String)
   is
      Tmp                    : Int_Array;
      Used_Horizontal        : Boolean := False;
      Horizontal_Edge        : Integer := -1;
      Horizontal_Edge_Target : Integer := -1;
   begin
      --  Swap mapping and old_mapping.
      Tmp := G.Mapping;
      G.Mapping := G.Old_Mapping;
      G.Old_Mapping := Tmp;

      for I in 0 .. G.Mapping_Size - 1 loop
         G.Mapping (I) := -1;
      end loop;

      for I in 0 .. G.Mapping_Size - 1 loop
         declare
            Target : constant Integer := G.Old_Mapping (I);
         begin
            if Target < 0 then
               null;
            elsif Target * 2 = I then
               --  Already in the correct place.
               G.Mapping (I) := Target;
            elsif G.Mapping (I - 1) < 0 then
               --  Nothing to the left: move left by one.
               G.Mapping (I - 1) := Target;
               if Horizontal_Edge = -1 then
                  Horizontal_Edge := I;
                  Horizontal_Edge_Target := Target;
                  declare
                     J : Integer := Target * 2 + 3;
                  begin
                     while J < I - 2 loop
                        G.Mapping (J) := Target;
                        J := J + 2;
                     end loop;
                  end;
               end if;
            elsif G.Mapping (I - 1) = Target then
               --  Combine with the branch line already to our left.
               null;
            else
               --  Cross over the branch line to our left.
               G.Mapping (I - 2) := Target;
               if Horizontal_Edge = -1 then
                  Horizontal_Edge_Target := Target;
                  Horizontal_Edge := I - 1;
                  declare
                     J : Integer := Target * 2 + 3;
                  begin
                     while J < I - 2 loop
                        G.Mapping (J) := Target;
                        J := J + 2;
                     end loop;
                  end;
               end if;
            end if;
         end;
      end loop;

      --  Copy the new mapping into old_mapping.
      G.Old_Mapping := G.Mapping;

      --  The new mapping may be one smaller than the old mapping.
      if G.Mapping (G.Mapping_Size - 1) < 0 then
         G.Mapping_Size := G.Mapping_Size - 1;
      end if;

      --  Output a line based on the new mapping.
      for I in 0 .. G.Mapping_Size - 1 loop
         declare
            Target : constant Integer := G.Mapping (I);
         begin
            if Target < 0 then
               Append (Line, ' ');
            elsif Target * 2 = I then
               Append (Line, '|');
            elsif Target = Horizontal_Edge_Target
              and then I /= Horizontal_Edge - 1
            then
               if I /= Target * 2 + 3 then
                  G.Mapping (I) := -1;
               end if;
               Used_Horizontal := True;
               Append (Line, '_');
            else
               if Used_Horizontal and then I < Horizontal_Edge then
                  G.Mapping (I) := -1;
               end if;
               Append (Line, '/');
            end if;
         end;
      end loop;

      if Is_Mapping_Correct (G) then
         Update_State (G, S_Padding);
      end if;
   end Output_Collapsing_Line;

   ---------------
   -- Next_Line --
   ---------------

   --  Emit the current state's line, advance the state, and return the padded
   --  text. Sets Is_Commit when the line just emitted was the commit line.
   procedure Next_Line
     (G         : in out Graph;
      Text      : out Unbounded_String;
      Is_Commit : out Boolean)
   is
      Line : Unbounded_String := Null_Unbounded_String;
   begin
      Is_Commit := False;
      case G.State is
         when S_Padding =>
            Output_Padding_Line (G, Line);
         when S_Skip =>
            Output_Skip_Line (G, Line);
         when S_Pre_Commit =>
            Output_Pre_Commit_Line (G, Line);
         when S_Commit =>
            Output_Commit_Line (G, Line);
            Is_Commit := True;
         when S_Post_Merge =>
            Output_Post_Merge_Line (G, Line);
         when S_Collapsing =>
            Output_Collapsing_Line (G, Line);
      end case;
      Pad (G, Line);
      Text := Line;
   end Next_Line;

   ------------
   -- Update --
   ------------

   procedure Update
     (G       : in out Graph;
      Commit  : Version.Objects.Hex_Object_Id;
      Parents : Version.Objects.Object_Id_Vectors.Vector) is
   begin
      Do_Update (G, Commit, Parents);
   end Update;

   ------------------
   -- Begin_Commit --
   ------------------

   function Begin_Commit (G : in out Graph) return Step is
      Result    : Step;
      Text      : Unbounded_String;
      Is_Commit : Boolean;
   begin
      --  Emit graph-only lines (pre-commit expansion / skip) until the commit
      --  line, which becomes the prefix for the commit's content.
      loop
         Next_Line (G, Text, Is_Commit);
         if Is_Commit then
            Result.Commit_Prefix := Text;
            exit;
         else
            Result.Pre_Lines.Append (To_String (Text));
         end if;
      end loop;

      return Result;
   end Begin_Commit;

   -------------
   -- Advance --
   -------------

   function Advance
     (G       : in out Graph;
      Commit  : Version.Objects.Hex_Object_Id;
      Parents : Version.Objects.Object_Id_Vectors.Vector) return Step is
   begin
      Do_Update (G, Commit, Parents);
      return Begin_Commit (G);
   end Advance;

   --------------------
   -- Separator_Line --
   --------------------

   function Separator_Line (G : in out Graph) return String is
      Line : Unbounded_String := Null_Unbounded_String;
   begin
      --  git's graph_padding_line. When the commit line has not been drawn yet
      --  (state COMMIT), draw the incoming columns as `| ` -- widening the
      --  commit's own column for an octopus -- and pad to the graph width.
      --  In any other state git just emits the next line.
      if G.State /= S_Commit then
         declare
            Ignored : Boolean;
         begin
            Next_Line (G, Line, Ignored);
            return To_String (Line);
         end;
      end if;

      for I in 0 .. G.Num_Columns - 1 loop
         Append (Line, '|');
         if G.Columns (I) = G.Commit and then G.Num_Parents > 2 then
            Append (Line, [1 .. (G.Num_Parents - 2) * 2 => ' ']);
         else
            Append (Line, ' ');
         end if;
      end loop;

      Pad (G, Line);
      G.Prev_State := S_Padding;
      return To_String (Line);
   end Separator_Line;

   ---------------
   -- Next_Line --
   ---------------

   function Next_Line (G : in out Graph) return String is
      Text      : Unbounded_String;
      Is_Commit : Boolean;
   begin
      Next_Line (G, Text, Is_Commit);
      return To_String (Text);
   end Next_Line;

   -----------------
   -- Is_Finished --
   -----------------

   function Is_Finished (G : Graph) return Boolean is (G.State = S_Padding);

   ---------------
   -- Remainder --
   ---------------

   function Remainder (G : in out Graph) return Line_Vectors.Vector is
      Result    : Line_Vectors.Vector;
      Text      : Unbounded_String;
      Is_Commit : Boolean;
   begin
      while G.State /= S_Padding loop
         Next_Line (G, Text, Is_Commit);
         Result.Append (To_String (Text));
      end loop;
      return Result;
   end Remainder;

end Version.Log_Graph;
