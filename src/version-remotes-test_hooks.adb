package body Version.Remotes.Test_Hooks is

   Before_Prune_Delete_Hook : Prune_Before_Delete_Hook := null;

   procedure Set_Prune_Before_Delete_Hook
     (Hook : Prune_Before_Delete_Hook)
   is
   begin
      Before_Prune_Delete_Hook := Hook;
   end Set_Prune_Before_Delete_Hook;

   procedure Run_Prune_Before_Delete_Hook is
   begin
      if Before_Prune_Delete_Hook /= null then
         Before_Prune_Delete_Hook.all;
      end if;
   end Run_Prune_Before_Delete_Hook;

end Version.Remotes.Test_Hooks;
