with Ada.Containers.Indefinite_Vectors;

--  Commit-message trailer manipulation, matching `git interpret-trailers`.
--
--  A trailer block is the last blank-line-delimited paragraph of a message,
--  provided it is not the only paragraph and contains at least one trailer
--  line (a `token: value` line whose token has no embedded whitespace).
--  Continuation lines (leading whitespace) and comment lines (`#`) are carried
--  along but never count as trailers.
package Version.Trailers is

   package String_Vectors is new
     Ada.Containers.Indefinite_Vectors (Positive, String);

   type Placement is (Placement_After, Placement_Before);

   --  What to do with a `--trailer` whose token already appears in the block
   --  (`--if-exists`) or does not (`--if-missing`), matching git's actions.
   type If_Exists_Mode is
     (IE_Add, IE_Add_If_Different, IE_Add_If_Different_Neighbor,
      IE_Replace, IE_Do_Nothing);
   type If_Missing_Mode is (IM_Add, IM_Do_Nothing);

   --  Apply `interpret-trailers` to Input.
   --
   --  Trailers holds the raw `--trailer` arguments (each `token<sep>value`,
   --  with `:` or `=` accepted as the separator; both normalise to `token:
   --  value`). Where controls whether new trailers are added after the last
   --  existing trailer (git `--where end`, the default) or before the first
   --  (`--where before`).
   --
   --  Only_Trailers emits just the trailer block; Only_Input suppresses the
   --  Trailers arguments (so the result reflects the input alone); Unfold
   --  joins continuation lines into their trailer. `--parse` is the
   --  combination Only_Trailers + Only_Input + Unfold.
   --  If_Exists / If_Missing follow git's defaults (add-if-different when the
   --  token is already present, add when it is missing).
   function Interpret
     (Input         : String;
      Trailers      : String_Vectors.Vector := String_Vectors.Empty_Vector;
      Where         : Placement := Placement_After;
      Only_Trailers : Boolean   := False;
      Only_Input    : Boolean   := False;
      Unfold        : Boolean   := False;
      If_Exists     : If_Exists_Mode := IE_Add_If_Different;
      If_Missing    : If_Missing_Mode := IM_Add)
      return String;

end Version.Trailers;
