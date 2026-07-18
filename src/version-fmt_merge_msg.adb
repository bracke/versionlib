with Ada.Characters.Latin_1;
with Ada.Containers.Indefinite_Vectors;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

with Version.Objects;

package body Version.Fmt_Merge_Msg is

   LF : Character renames Ada.Characters.Latin_1.LF;

   package String_Vectors is new
     Ada.Containers.Indefinite_Vectors (Positive, String);

   type Entry_Rec is record
      Type_Word : Unbounded_String;
      Name      : Unbounded_String;
      Src       : Unbounded_String;   --  "" when the description had no "of"
      Sha       : Unbounded_String;
   end record;

   package Entry_Vectors is new
     Ada.Containers.Indefinite_Vectors (Positive, Entry_Rec);

   type Group_Rec is record
      Origin_Key : Unbounded_String;
      Src        : Unbounded_String;
      Type_Word  : Unbounded_String;
      Names      : String_Vectors.Vector;
   end record;

   package Group_Vectors is new
     Ada.Containers.Indefinite_Vectors (Positive, Group_Rec);

   function Split_Lines (S : String) return String_Vectors.Vector is
      Result : String_Vectors.Vector;
      Start  : Positive := (if S'Length > 0 then S'First else 1);
   begin
      if S'Length = 0 then
         return Result;
      end if;
      for I in S'Range loop
         if S (I) = LF then
            Result.Append (S (Start .. I - 1));
            Start := I + 1;
         end if;
      end loop;
      if Start <= S'Last then
         Result.Append (S (Start .. S'Last));
      end if;
      return Result;
   end Split_Lines;

   function Plural (Word : String) return String is
   begin
      if Word'Length > 0 and then Word (Word'Last) = 'h' then
         return Word & "es";
      else
         return Word & "s";
      end if;
   end Plural;

   function Names_List (Names : String_Vectors.Vector) return String is
      Result : Unbounded_String;
      N      : constant Natural := Natural (Names.Length);
   begin
      for I in Names.First_Index .. Names.Last_Index loop
         if I = Names.Last_Index and then N >= 2 then
            Append (Result, " and ");
         elsif I > Names.First_Index then
            Append (Result, ", ");
         end if;
         Append (Result, "'" & Names.Element (I) & "'");
      end loop;
      return To_String (Result);
   end Names_List;

   --  Parse a FETCH_HEAD description ("branch 'x' of URL", "tag 'x'", ...).
   procedure Parse_Description
     (Desc      : String;
      Type_Word : out Unbounded_String;
      Name      : out Unbounded_String;
      Src       : out Unbounded_String)
   is
      Q1 : constant Natural := Ada.Strings.Fixed.Index (Desc, "'");
   begin
      Type_Word := Null_Unbounded_String;
      Name      := Null_Unbounded_String;
      Src       := Null_Unbounded_String;
      if Q1 = 0 then
         return;
      end if;
      Type_Word :=
        To_Unbounded_String
          (Ada.Strings.Fixed.Trim
             (Desc (Desc'First .. Q1 - 1), Ada.Strings.Both));
      declare
         Q2 : constant Natural :=
           Ada.Strings.Fixed.Index (Desc (Q1 + 1 .. Desc'Last), "'");
      begin
         if Q2 = 0 then
            return;
         end if;
         Name := To_Unbounded_String (Desc (Q1 + 1 .. Q2 - 1));
         declare
            Rest : constant String := Desc (Q2 + 1 .. Desc'Last);
            Of_M : constant String := " of ";
         begin
            if Rest'Length > Of_M'Length
              and then Rest (Rest'First .. Rest'First + Of_M'Length - 1) = Of_M
            then
               Src :=
                 To_Unbounded_String (Rest (Rest'First + Of_M'Length .. Rest'Last));
            end if;
         end;
      end;
   end Parse_Description;

   function Tag_Message
     (Repo : Version.Repository.Repository_Handle;
      Sha  : String) return String
   is
      use type Version.Objects.Object_Kind;
      Obj : constant Version.Objects.Git_Object :=
        Version.Objects.Read_Object
          (Repo, Version.Objects.To_Object_Id (Sha));
   begin
      if Version.Objects.Kind (Obj) /= Version.Objects.Tag_Object then
         return "";
      end if;
      declare
         Body_Text : constant String := Version.Objects.Content (Obj);
         Sep : constant Natural :=
           Ada.Strings.Fixed.Index (Body_Text, LF & LF);
         Msg_First : Natural;
         Msg_Last  : Natural := Body_Text'Last;
      begin
         if Sep = 0 then
            return "";
         end if;
         Msg_First := Sep + 2;
         --  Strip trailing newlines; git re-adds a single one in the caller.
         while Msg_Last >= Msg_First and then Body_Text (Msg_Last) = LF loop
            Msg_Last := Msg_Last - 1;
         end loop;
         return Body_Text (Msg_First .. Msg_Last);
      end;
   end Tag_Message;

   function Format
     (Repo           : Version.Repository.Repository_Handle;
      Input          : String;
      Current_Branch : String)
      return String
   is
      Lines   : constant String_Vectors.Vector := Split_Lines (Input);
      Entries : Entry_Vectors.Vector;
      Groups  : Group_Vectors.Vector;
      Result  : Unbounded_String;
   begin
      --  Parse for-merge lines.
      for Line of Lines loop
         declare
            T1 : constant Natural :=
              Ada.Strings.Fixed.Index (Line, "" & Ada.Characters.Latin_1.HT);
         begin
            if T1 /= 0 then
               declare
                  Sha  : constant String := Line (Line'First .. T1 - 1);
                  Rest : constant String := Line (T1 + 1 .. Line'Last);
                  T2   : constant Natural :=
                    Ada.Strings.Fixed.Index
                      (Rest, "" & Ada.Characters.Latin_1.HT);
               begin
                  if T2 /= 0 then
                     declare
                        Flag : constant String := Rest (Rest'First .. T2 - 1);
                        Desc : constant String := Rest (T2 + 1 .. Rest'Last);
                        TW, NM, SR : Unbounded_String;
                     begin
                        --  Skip not-for-merge lines and empty descriptions.
                        if Flag'Length = 0 and then Desc'Length > 0 then
                           Parse_Description (Desc, TW, NM, SR);
                           if Length (NM) > 0 then
                              Entries.Append
                                (Entry_Rec'
                                   (Type_Word => TW, Name => NM, Src => SR,
                                    Sha => To_Unbounded_String (Sha)));
                           else
                              --  A description that is just a URL is a fetch
                              --  of that remote's HEAD; git reports it as the
                              --  URL alone, or as "HEAD" beside named refs
                              --  from the same URL.
                              Entries.Append
                                (Entry_Rec'
                                   (Type_Word => Null_Unbounded_String,
                                    Name      => To_Unbounded_String ("HEAD"),
                                    Src       => To_Unbounded_String (Desc),
                                    Sha       => To_Unbounded_String (Sha)));
                           end if;
                        end if;
                     end;
                  end if;
               end;
            end if;
         end;
      end loop;

      --  Group by (origin, type), preserving first-appearance order. Local
      --  refs (no "of") use the ref name as origin, so each stands alone.
      for E of Entries loop
         declare
            Origin : constant Unbounded_String :=
              (if Length (E.Src) > 0 then E.Src else E.Name);
            Found : Boolean := False;
         begin
            for G of Groups loop
               if G.Origin_Key = Origin and then G.Type_Word = E.Type_Word then
                  G.Names.Append (To_String (E.Name));
                  Found := True;
                  exit;
               end if;
            end loop;
            if not Found then
               declare
                  G : Group_Rec;
               begin
                  G.Origin_Key := Origin;
                  G.Src        := E.Src;
                  G.Type_Word  := E.Type_Word;
                  G.Names.Append (To_String (E.Name));
                  Groups.Append (G);
               end;
            end if;
         end;
      end loop;

      if Groups.Is_Empty then
         return "";
      end if;

      Append (Result, "Merge ");

      --  git groups by source: every kind fetched from one URL is listed
      --  together and the "of <url>" is written once, after all of them.
      --  Separate sources are joined with "; ".
      declare
         Emitted : Natural := 0;
         Done    : array (1 .. Natural (Groups.Length)) of Boolean :=
           [others => False];
      begin
         for I in Groups.First_Index .. Groups.Last_Index loop
            if not Done (I) then
               declare
                  Src : constant Unbounded_String := Groups.Element (I).Src;
                  Only_Head : Boolean := True;
                  Part : Unbounded_String;
                  Kinds : Natural := 0;
               begin
                  for J in I .. Groups.Last_Index loop
                     if not Done (J) and then Groups.Element (J).Src = Src then
                        declare
                           G  : constant Group_Rec := Groups.Element (J);
                           TW : constant String :=
                             (if Length (G.Type_Word) > 0
                              then To_String (G.Type_Word) else "commit");
                           Word : constant String :=
                             (if Natural (G.Names.Length) > 1
                              then Plural (TW) else TW);
                           Is_Head : constant Boolean :=
                             Length (G.Type_Word) = 0
                             and then Natural (G.Names.Length) = 1
                             and then G.Names.Element (G.Names.First_Index)
                                      = "HEAD";
                        begin
                           --  Local refs (no URL) each stand alone, as git
                           --  reports them.
                           exit when Length (Src) = 0 and then J > I;

                           Done (J) := True;
                           if Kinds > 0 then
                              Append (Part, ", ");
                           end if;
                           if Is_Head then
                              Append (Part, "HEAD");
                           else
                              Only_Head := False;
                              Append (Part, Word & " " & Names_List (G.Names));
                           end if;
                           Kinds := Kinds + 1;
                        end;
                     end if;
                  end loop;

                  if Emitted > 0 then
                     Append (Result, "; ");
                  end if;

                  --  A source that contributed nothing but its HEAD is
                  --  reported as the URL alone.
                  if Only_Head and then Length (Src) > 0 then
                     Append (Result, To_String (Src));
                  else
                     Append (Result, To_String (Part));
                     if Length (Src) > 0 then
                        Append (Result, " of " & To_String (Src));
                     end if;
                  end if;
                  Emitted := Emitted + 1;
               end;
            end if;
         end loop;
      end;

      --  git omits the "into <branch>" suffix on the conventional defaults.
      if Current_Branch'Length > 0
        and then Current_Branch /= "master"
        and then Current_Branch /= "main"
      then
         Append (Result, " into " & Current_Branch);
      end if;

      --  Append the message body of any merged annotated tags.
      for E of Entries loop
         if To_String (E.Type_Word) = "tag" then
            declare
               Msg : constant String := Tag_Message (Repo, To_String (E.Sha));
            begin
               if Msg'Length > 0 then
                  Append (Result, LF & LF & Msg);
               end if;
            end;
         end if;
      end loop;

      Append (Result, LF);
      return To_String (Result);
   end Format;

end Version.Fmt_Merge_Msg;
