with Ada.Calendar;
with Ada.Command_Line;
with Ada.Directories;
with Ada.Text_IO;

with Version.Status;

procedure Bench_Status is
   use type Ada.Calendar.Time;
   Iterations : constant Positive :=
     (if Ada.Command_Line.Argument_Count >= 1
      then Positive'Value (Ada.Command_Line.Argument (1))
      else 100);

   Old_Dir : constant String := Ada.Directories.Current_Directory;
   Start   : Ada.Calendar.Time;
   Stop    : Ada.Calendar.Time;
   Result  : Version.Status.Status_Result;
begin
   Start := Ada.Calendar.Clock;
   for I in 1 .. Iterations loop
      Result := Version.Status.Current_Status;
   end loop;
   Stop := Ada.Calendar.Clock;

   Ada.Text_IO.Put_Line ("bench_status");
   Ada.Text_IO.Put_Line ("repository=" & Old_Dir);
   Ada.Text_IO.Put_Line ("iterations=" & Positive'Image (Iterations));
   Ada.Text_IO.Put_Line ("changes=" & Natural'Image (Natural (Result.Changes.Length)));
   Ada.Text_IO.Put_Line ("staged=" & Natural'Image (Natural (Result.Staged.Length)));
   Ada.Text_IO.Put_Line ("untracked=" & Natural'Image (Natural (Result.Untracked.Length)));
   Ada.Text_IO.Put_Line ("elapsed_seconds=" & Duration'Image (Stop - Start));
end Bench_Status;
