with Version.Revert_State;

package Version.Revert is

   procedure Start
     (Revisions : Version.Revert_State.Commit_Vectors.Vector;
      Mainline  : Natural := 0;
      No_Commit : Boolean := False);
   --  No_Commit is git's -n/--no-commit: apply the reverts to the index and
   --  working tree but leave HEAD (and the sequencer state) untouched.
   procedure Start (Revision : String);
   procedure Start (Revision : String; Mainline : Natural);
   procedure Continue_Revert;
   procedure Abort_Revert;

end Version.Revert;
