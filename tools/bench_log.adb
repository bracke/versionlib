with Ada.Calendar;
with Ada.Command_Line;
with Ada.Directories;
with Ada.Text_IO;
with Ada.Strings.Unbounded;

with Version.Log;
with Version.Repository;

procedure Bench_Log is
   use type Ada.Calendar.Time;
   Iterations : constant Positive :=
     (if Ada.Command_Line.Argument_Count >= 1
      then Positive'Value (Ada.Command_Line.Argument (1))
      else 100);

   Old_Dir : constant String := Ada.Directories.Current_Directory;
   Repo    : constant Version.Repository.Repository_Handle := Version.Repository.Open;
   Start   : Ada.Calendar.Time;
   Stop    : Ada.Calendar.Time;
   Text    : Ada.Strings.Unbounded.Unbounded_String;
begin
   Start := Ada.Calendar.Clock;
   for I in 1 .. Iterations loop
      Text := Ada.Strings.Unbounded.To_Unbounded_String (Version.Log.Log_Head (Repo));
   end loop;
   Stop := Ada.Calendar.Clock;

   Ada.Text_IO.Put_Line ("bench_log");
   Ada.Text_IO.Put_Line ("repository=" & Old_Dir);
   Ada.Text_IO.Put_Line ("iterations=" & Positive'Image (Iterations));
   Ada.Text_IO.Put_Line
     ("last_output_bytes="
      & Natural'Image (Ada.Strings.Unbounded.Length (Text)));
   Ada.Text_IO.Put_Line ("elapsed_seconds=" & Duration'Image (Stop - Start));
end Bench_Log;
