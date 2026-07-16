with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Version.Repository;

--  `.mailmap`: the canonical name and address for an identity that appears in
--  the history under an old or misspelled one.
--
--  A line is `New Name <new@mail> Old Name <old@mail>`, with either name and
--  the old name optional.  A rule that names the old identity's *name* as well
--  as its address only rewrites that pairing; a rule that gives only the old
--  address rewrites every identity using it.
package Version.Mailmap is

   use Ada.Strings.Unbounded;

   type Entries is private;

   --  The repository's `.mailmap` (empty when there is none, including in a
   --  bare repository).
   function Load
     (Repo : Version.Repository.Repository_Handle)
      return Entries;

   function Parse (Content : String) return Entries;

   --  The identity Name/Email maps to; unchanged when no rule matches.
   procedure Apply
     (Map       : Entries;
      Name      : String;
      Email     : String;
      Out_Name  : out Unbounded_String;
      Out_Email : out Unbounded_String);

private

   type Mailmap_Entry is record
      Old_Email    : Unbounded_String;   --  lowercased match key
      Has_Old_Name : Boolean := False;
      Old_Name     : Unbounded_String;
      Has_New_Name : Boolean := False;
      New_Name     : Unbounded_String;
      New_Email    : Unbounded_String;
   end record;

   package Entry_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Mailmap_Entry);

   type Entries is record
      Items : Entry_Vectors.Vector;
   end record;

end Version.Mailmap;
