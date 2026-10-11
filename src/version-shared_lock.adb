with Ada.Task_Identification;

package body Version.Shared_Lock is

   use type Ada.Task_Identification.Task_Id;

   protected Lock is
      entry Seize;
      procedure Release;
   private
      entry Wait;
      Owner : Ada.Task_Identification.Task_Id := Ada.Task_Identification.Null_Task_Id;
      Depth : Natural := 0;
   end Lock;

   protected body Lock is

      entry Seize when True is
      begin
         if Depth > 0 and then Owner = Seize'Caller then
            Depth := Depth + 1;
         elsif Depth = 0 then
            Owner := Seize'Caller;
            Depth := 1;
         else
            requeue Wait;
         end if;
      end Seize;

      entry Wait when Depth = 0 is
      begin
         Owner := Wait'Caller;
         Depth := 1;
      end Wait;

      procedure Release is
      begin
         if Depth > 0 then
            Depth := Depth - 1;
            if Depth = 0 then
               Owner := Ada.Task_Identification.Null_Task_Id;
            end if;
         end if;
      end Release;

   end Lock;

   overriding procedure Initialize (Item : in out Hold) is
      pragma Unreferenced (Item);
   begin
      Lock.Seize;
   end Initialize;

   overriding procedure Finalize (Item : in out Hold) is
      pragma Unreferenced (Item);
   begin
      Lock.Release;
   end Finalize;

end Version.Shared_Lock;
