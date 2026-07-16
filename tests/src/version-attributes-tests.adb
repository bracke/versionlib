with Ada.Directories;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Git_Fixtures;
with Version.Init;
with Version.Mailmap;
with Version.Repository;

package body Version.Attributes.Tests is

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

   procedure Build (Root : String) is
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run
        (Root,
         "printf '*.txt text -diff foo=bar\n*.bin binary\n"
         & "[attr]mymacro text merge=custom\n' > .gitattributes"
         & " && mkdir -p sub"
         & " && printf 'h.bin mymacro !diff\nsub/ never\n' "
         & "> sub/.gitattributes");
   end Build;

   function State_Of
     (Repo : Version.Repository.Repository_Handle;
      Path : String;
      Name : String)
      return String
   is (Version.Attributes.State_Image
         (Version.Attributes.Lookup (Repo, Path, Name)));

   --  The three rules that are easy to get wrong: a deeper file overrides a
   --  shallower one, a macro sets an attribute of its own name *and* expands,
   --  and `!attr` blocks -- it does not expand.
   procedure Precedence_And_Macros
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Build (Root);
      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
      begin
         Assert (State_Of (Repo, "f.txt", "text") = "set", "*.txt sets text");
         Assert (State_Of (Repo, "f.txt", "diff") = "unset", "*.txt -diff");
         Assert (State_Of (Repo, "f.txt", "foo") = "bar", "foo=bar");
         Assert (State_Of (Repo, "f.txt", "merge") = "unspecified",
                 "merge is not mentioned for a .txt");

         --  `binary` expands to -diff -merge -text and sets `binary` itself.
         Assert (State_Of (Repo, "top.bin", "binary") = "set",
                 "the macro sets an attribute of its own name");
         Assert (State_Of (Repo, "top.bin", "text") = "unset",
                 "the binary macro expands to -text");

         --  sub/.gitattributes wins over the root's, and `!diff` there leaves
         --  diff unspecified rather than unset.
         Assert (State_Of (Repo, "sub/h.bin", "merge") = "custom",
                 "mymacro's merge=custom must win, got "
                 & State_Of (Repo, "sub/h.bin", "merge"));
         Assert (State_Of (Repo, "sub/h.bin", "diff") = "unspecified",
                 "!diff must block the binary macro's -diff, got "
                 & State_Of (Repo, "sub/h.bin", "diff"));

         --  A trailing-slash pattern never matches a file.
         Assert (State_Of (Repo, "sub/anything.c", "never") = "unspecified",
                 "a `sub/` pattern must not reach files inside sub");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Precedence_And_Macros;

   --  A mailmap rule that names the old identity only rewrites that exact
   --  pairing; one that gives only the address rewrites every use of it.
   procedure Mailmap_Rules
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      Map : constant Version.Mailmap.Entries :=
        Version.Mailmap.Parse
          ("Real Name <real@x> <old@x>" & ASCII.LF
           & "Only <only@x>" & ASCII.LF
           & "Named <n@x> Old Named <on@x>" & ASCII.LF);

      procedure Check (Name, Email, Want : String) is
         Out_Name, Out_Email : Unbounded_String;
      begin
         Version.Mailmap.Apply (Map, Name, Email, Out_Name, Out_Email);

         declare
            Got : constant String :=
              To_String (Out_Name) & " <" & To_String (Out_Email) & ">";
         begin
            Assert (Got = Want, Name & " <" & Email & "> => " & Got
                    & ", expected " & Want);
         end;
      end Check;

   begin
      Check ("Old", "old@x", "Real Name <real@x>");
      Check ("Whoever", "only@x", "Only <only@x>");
      Check ("Old Named", "on@x", "Named <n@x>");
      --  The name does not match the rule's old name: it stands.
      Check ("Other", "on@x", "Other <on@x>");
      Check ("Nobody", "nb@x", "Nobody <nb@x>");
   end Mailmap_Rules;

   overriding procedure Register_Tests (T : in out Test_Case) is
   begin
      Register_Routine
        (T, Precedence_And_Macros'Access,
         "Attributes: file precedence, macro expansion, and !attr");
      Register_Routine
        (T, Mailmap_Rules'Access,
         "Mailmap: name-qualified rules only rewrite that pairing");
   end Register_Tests;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Attributes");
   end Name;

end Version.Attributes.Tests;
