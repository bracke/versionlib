with Ada.Strings.Unbounded;

with Version.Grep;
with Version.Objects;
with Version.Repository;

--  git's pickaxe (diffcore-pickaxe): whether one path's change is worth
--  showing under -S<string> (the string's occurrence count differs
--  between the two sides) or -G<regex> (a changed line matches).
package Version.Pickaxe is

   type Spec is record
      Active      : Boolean := False;
      Pattern     : Ada.Strings.Unbounded.Unbounded_String;
      Regex       : Boolean := False;   --  -G, else -S
      --  -S's string is a regex too under --pickaxe-regex.
      Regex_String : Boolean := False;
      Kind        : Version.Grep.Pattern_Kind := Version.Grep.Basic_Regex;
      Ignore_Case : Boolean := False;
   end record;

   --  Whether the change from the old blob to the new one (either absent
   --  when the path was added or deleted) matches the pickaxe.
   function Pair_Matches
     (Repo        : Version.Repository.Repository_Handle;
      Old_Present : Boolean;
      Old_Id      : Version.Objects.Hex_Object_Id;
      New_Present : Boolean;
      New_Id      : Version.Objects.Hex_Object_Id;
      Pick        : Spec) return Boolean;

   --  The same over the two texts.
   function Texts_Match (Old_Text, New_Text : String; Pick : Spec) return Boolean;

end Version.Pickaxe;
