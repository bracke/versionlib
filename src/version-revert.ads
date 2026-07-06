with Version.Revert_State;

package Version.Revert is

   procedure Start
     (Revisions : Version.Revert_State.Commit_Vectors.Vector;
      Mainline  : Natural := 0);
   procedure Start (Revision : String);
   procedure Start (Revision : String; Mainline : Natural);
   procedure Continue_Revert;
   procedure Abort_Revert;

end Version.Revert;
