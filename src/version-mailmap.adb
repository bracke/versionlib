with Version.Files;

package body Version.Mailmap is

   LF : constant Character := Character'Val (10);

   function Lower (S : String) return String is
      R : String := S;
   begin
      for I in R'Range loop
         if R (I) in 'A' .. 'Z' then
            R (I) :=
              Character'Val
                (Character'Pos (R (I)) - Character'Pos ('A')
                 + Character'Pos ('a'));
         end if;
      end loop;

      return R;
   end Lower;

   function Trim (S : String) return String is
      F : Integer := S'First;
      L : Integer := S'Last;
   begin
      while F <= L
        and then (S (F) = ' ' or else S (F) = Character'Val (9))
      loop
         F := F + 1;
      end loop;

      while L >= F
        and then (S (L) = ' ' or else S (L) = Character'Val (9)
                  or else S (L) = Character'Val (13))
      loop
         L := L - 1;
      end loop;

      return S (F .. L);
   end Trim;

   procedure Parse_Line (Line : String; Map : in out Entry_Vectors.Vector) is
      T : constant String := Trim (Line);
      LT1, GT1, LT2, GT2 : Natural := 0;
   begin
      if T'Length = 0 or else T (T'First) = '#' then
         return;
      end if;

      for I in T'Range loop
         if T (I) = '<' then
            if LT1 = 0 then
               LT1 := I;
            elsif GT1 /= 0 and then LT2 = 0 then
               LT2 := I;
            end if;
         elsif T (I) = '>' then
            if GT1 = 0 then
               GT1 := I;
            elsif LT2 /= 0 and then GT2 = 0 then
               GT2 := I;
            end if;
         end if;
      end loop;

      if LT1 = 0 or else GT1 = 0 or else GT1 < LT1 then
         return;
      end if;

      declare
         E        : Mailmap_Entry;
         New_Name : constant String := Trim (T (T'First .. LT1 - 1));
      begin
         E.Has_New_Name := New_Name'Length > 0;
         E.New_Name := To_Unbounded_String (New_Name);

         if LT2 /= 0 and then GT2 > LT2 then
            --  Two addresses: "<new> <old>" (each may carry a name).
            E.New_Email := To_Unbounded_String (T (LT1 + 1 .. GT1 - 1));
            E.Old_Email :=
              To_Unbounded_String (Lower (T (LT2 + 1 .. GT2 - 1)));

            declare
               Old_Name : constant String := Trim (T (GT1 + 1 .. LT2 - 1));
            begin
               E.Has_Old_Name := Old_Name'Length > 0;
               E.Old_Name := To_Unbounded_String (Old_Name);
            end;
         else
            --  One address: it gets the proper name, the address stands.
            E.New_Email := To_Unbounded_String (T (LT1 + 1 .. GT1 - 1));
            E.Old_Email :=
              To_Unbounded_String (Lower (T (LT1 + 1 .. GT1 - 1)));
         end if;

         Map.Append (E);
      end;
   end Parse_Line;

   -----------
   -- Parse --
   -----------

   function Parse (Content : String) return Entries is
      Result : Entries;
      Start  : Natural := Content'First;
   begin
      for I in Content'Range loop
         if Content (I) = LF then
            Parse_Line (Content (Start .. I - 1), Result.Items);
            Start := I + 1;
         end if;
      end loop;

      if Start <= Content'Last then
         Parse_Line (Content (Start .. Content'Last), Result.Items);
      end if;

      return Result;
   end Parse;

   ----------
   -- Load --
   ----------

   function Load
     (Repo : Version.Repository.Repository_Handle)
      return Entries
   is
      Root : constant String := Version.Repository.Root_Path (Repo);
      Path : constant String := Version.Files.Join (Root, ".mailmap");
   begin
      if Version.Files.Is_Ordinary_File (Path) then
         return Parse (Version.Files.Read_Binary_File (Path));
      end if;

      return (Items => Entry_Vectors.Empty_Vector);
   exception
      --  A bare repository has no worktree root: no mailmap, not an error.
      when others =>
         return (Items => Entry_Vectors.Empty_Vector);
   end Load;

   -----------
   -- Apply --
   -----------

   function Apply_To
     (Map   : Entries;
      Name  : String;
      Email : String)
      return Natural
   is
      Key      : constant String := Lower (Email);
      Name_Key : constant String := Lower (Name);
      Named    : Natural := 0;
      Default  : Natural := 0;
   begin
      for I in Map.Items.First_Index .. Map.Items.Last_Index loop
         declare
            E : constant Mailmap_Entry := Map.Items (I);
         begin
            if To_String (E.Old_Email) = Key then
               if E.Has_Old_Name then
                  --  A rule that names the old identity only rewrites that
                  --  exact name/address pairing.
                  if Named = 0
                    and then Lower (To_String (E.Old_Name)) = Name_Key
                  then
                     Named := I;
                  end if;
               elsif Default = 0 then
                  Default := I;
               end if;
            end if;
         end;
      end loop;

      return (if Named /= 0 then Named else Default);
   end Apply_To;

   procedure Apply
     (Map       : Entries;
      Name      : String;
      Email     : String;
      Out_Name  : out Unbounded_String;
      Out_Email : out Unbounded_String)
   is
      Chosen : constant Natural := Apply_To (Map, Name, Email);
   begin
      Out_Name := To_Unbounded_String (Name);
      Out_Email := To_Unbounded_String (Email);

      if Chosen = 0 then
         return;
      end if;

      declare
         E : constant Mailmap_Entry := Map.Items (Chosen);
      begin
         if E.Has_New_Name then
            Out_Name := E.New_Name;
         end if;

         Out_Email := E.New_Email;
      end;
   end Apply;

end Version.Mailmap;
