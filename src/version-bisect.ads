with Ada.Strings.Unbounded;

with Version.Objects;
with Version.Repository;

--  Git-compatible `bisect` state machine and commit-selection algorithm.
--
--  All session state lives under the git dir, matching git's on-disk layout:
--  BISECT_START (branch/commit to return to), BISECT_TERMS (<bad>\n<good>\n),
--  BISECT_NAMES, BISECT_LOG, and refs/bisect/<term-bad>,
--  refs/bisect/<term-good>-<oid>, refs/bisect/skip-<oid>.  The CLI drives the
--  I/O side (checkout, `show`, printing); this package owns the graph maths and
--  the byte-exact log/status text.
package Version.Bisect is

   use Ada.Strings.Unbounded;

   type Terms is record
      Bad  : Unbounded_String;   --  "new" state, default "bad"
      Good : Unbounded_String;   --  "old" state, default "good"
   end record;

   function Default_Terms return Terms;

   --  True when a bisection session is active (BISECT_START present).
   function In_Progress
     (Repo : Version.Repository.Repository_Handle) return Boolean;

   --  Terms recorded in BISECT_TERMS (or defaults when absent).
   function Current_Terms
     (Repo : Version.Repository.Repository_Handle) return Terms;

   --  Marked-commit accessors (read refs/bisect/*).
   function Has_Bad
     (Repo : Version.Repository.Repository_Handle) return Boolean;
   function Bad_Id
     (Repo : Version.Repository.Repository_Handle)
      return Version.Objects.Hex_Object_Id;
   function Good_Count
     (Repo : Version.Repository.Repository_Handle) return Natural;

   package Id_Vectors renames Version.Objects.Object_Id_Vectors;

   function Good_Ids
     (Repo : Version.Repository.Repository_Handle) return Id_Vectors.Vector;
   function Skip_Ids
     (Repo : Version.Repository.Repository_Handle) return Id_Vectors.Vector;

   --  Where the session should return HEAD on reset (BISECT_START content).
   function Start_Ref
     (Repo : Version.Repository.Repository_Handle) return String;

   ----------------------------------------------------------------------------
   --  Result of computing the next bisection step from the on-disk state.

   type Status_Kind is
     (Need_Both,       --  no good and no bad yet
      Need_Good,       --  bad known, waiting for a good
      Need_Bad,        --  good(s) known, waiting for a bad
      Continue,        --  a commit (Rev) should be tested next
      Found,           --  Rev is the first bad commit
      Only_Skipped);   --  nothing testable remains but all candidates skipped

   type Bisection is record
      Kind  : Status_Kind := Need_Both;
      Rev   : Version.Objects.Object_Id_Storage :=
        Version.Objects.Zero_Object_Id;
      Left  : Natural := 0;   --  revisions left to test after this
      All_N : Natural := 0;   --  candidate set size
      Steps : Natural := 0;   --  estimated remaining steps
   end record;

   function Compute
     (Repo : Version.Repository.Repository_Handle) return Bisection;

   --  Human-readable "waiting ..." text for the waiting kinds (git wording;
   --  always literal good/bad regardless of custom terms).
   function Status_Text
     (Repo : Version.Repository.Repository_Handle;
      Kind : Status_Kind) return String;

   ----------------------------------------------------------------------------
   --  State mutation.

   --  Begin a session: writes BISECT_START/NAMES/TERMS and seeds BISECT_LOG.
   procedure Start
     (Repo      : Version.Repository.Repository_Handle;
      Start_Ref : String;
      Term_Bad  : String;
      Term_Good : String);

   --  Record a good/bad/skip marker ref (refs/bisect/*).
   procedure Mark_Good
     (Repo : Version.Repository.Repository_Handle;
      Id   : Version.Objects.Hex_Object_Id);
   procedure Mark_Bad
     (Repo : Version.Repository.Repository_Handle;
      Id   : Version.Objects.Hex_Object_Id);
   procedure Mark_Skip
     (Repo : Version.Repository.Repository_Handle;
      Id   : Version.Objects.Hex_Object_Id);

   --  Rewrite BISECT_TERMS (used when `new`/`old` establish terms lazily).
   procedure Set_Terms
     (Repo      : Version.Repository.Repository_Handle;
      Term_Bad  : String;
      Term_Good : String);

   --  Append a raw line (no trailing newline) to BISECT_LOG.
   procedure Append_Log
     (Repo : Version.Repository.Repository_Handle;
      Line : String);

   function Read_Log
     (Repo : Version.Repository.Repository_Handle) return String;

   --  Remove all session state (state files + refs/bisect/).
   procedure Clear (Repo : Version.Repository.Repository_Handle);

   --  Number of steps git would report for a candidate set of size All_N.
   function Estimate_Steps (All_N : Natural) return Natural;

end Version.Bisect;
