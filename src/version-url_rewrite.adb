with Ada.Characters.Handling;
with Ada.Strings.Unbounded;

with Version.Config;

package body Version.Url_Rewrite is

   use Ada.Strings.Unbounded;

   --  Extract <base> from a section name of the form: url "<base>"
   function Url_Section_Base (Section : String) return String is
      Prefix : constant String := "url """;
   begin
      if Section'Length > Prefix'Length + 1
        and then Section (Section'First .. Section'First + Prefix'Length - 1)
                 = Prefix
        and then Section (Section'Last) = '"'
      then
         return Section (Section'First + Prefix'Length .. Section'Last - 1);
      end if;
      return "";
   end Url_Section_Base;

   --  Best (longest-prefix) rewrite among entries whose key equals Key_Name.
   procedure Best_Match
     (Items     : Version.Config.Config_Entry_Vectors.Vector;
      Url       : String;
      Key_Name  : String;
      Base      : out Unbounded_String;
      Match_Len : out Natural)
   is
   begin
      Base := Null_Unbounded_String;
      Match_Len := 0;
      for I in Items.First_Index .. Items.Last_Index loop
         declare
            Item    : constant Version.Config.Config_Entry := Items.Element (I);
            Sect    : constant String := To_String (Item.Section);
            The_Base : constant String := Url_Section_Base (Sect);
            Value   : constant String := To_String (Item.Value);
         begin
            if The_Base'Length > 0
              and then Ada.Characters.Handling.To_Lower
                         (To_String (Item.Key)) = Key_Name
              and then Value'Length > Match_Len
              and then Url'Length >= Value'Length
              and then Url (Url'First .. Url'First + Value'Length - 1) = Value
            then
               Match_Len := Value'Length;
               Base := To_Unbounded_String (The_Base);
            end if;
         end;
      end loop;
   end Best_Match;

   function Rewrite
     (Repo     : Version.Repository.Repository_Handle;
      Url      : String;
      For_Push : Boolean := False)
      return String
   is
      Items     : constant Version.Config.Config_Entry_Vectors.Vector :=
        Version.Config.Read_All (Repo);
      Base      : Unbounded_String;
      Match_Len : Natural := 0;
   begin
      if For_Push then
         Best_Match (Items, Url, "pushinsteadof", Base, Match_Len);
      end if;
      if Match_Len = 0 then
         Best_Match (Items, Url, "insteadof", Base, Match_Len);
      end if;
      if Match_Len > 0 then
         return To_String (Base) & Url (Url'First + Match_Len .. Url'Last);
      end if;
      return Url;
   exception
      when others =>
         return Url;   --  never let URL rewriting break a transport operation
   end Rewrite;

end Version.Url_Rewrite;
