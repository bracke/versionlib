with Version.Cherry_Pick_State;

package Version.Cherry_Pick is

   procedure Start
     (Revisions : Version.Cherry_Pick_State.Commit_Vectors.Vector;
      Mainline  : Natural := 0);
   procedure Start (Revision : String);
   procedure Start (Revision : String; Mainline : Natural);
   procedure Continue_Cherry_Pick;
   procedure Abort_Cherry_Pick;

end Version.Cherry_Pick;
