private package Version.Remotes.Test_Hooks is

   type Prune_Before_Delete_Hook is access procedure;

   procedure Set_Prune_Before_Delete_Hook
     (Hook : Prune_Before_Delete_Hook);

   procedure Run_Prune_Before_Delete_Hook;

end Version.Remotes.Test_Hooks;
