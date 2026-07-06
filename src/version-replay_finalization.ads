with Version.Objects;
with Version.Repository;

package Version.Replay_Finalization is

   type Head_Kind is (Symbolic_Head, Detached_Head);

   procedure Advance_Head
     (Repo     : Version.Repository.Repository_Handle;
      Kind     : Head_Kind;
      Head_Ref : String;
      Old_Head : Version.Objects.Hex_Object_Id;
      New_Head : Version.Objects.Hex_Object_Id;
      Message  : String);

end Version.Replay_Finalization;
