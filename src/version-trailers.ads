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
   function Interpret
     (Input         : String;
      Trailers      : String_Vectors.Vector := String_Vectors.Empty_Vector;
      Where         : Placement := Placement_After;
      Only_Trailers : Boolean   := False;
      Only_Input    : Boolean   := False;
      Unfold        : Boolean   := False)
      return String;

end Version.Trailers;
