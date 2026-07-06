with Ada.Calendar;
with Ada.Command_Line;
with Ada.Directories;
with Ada.Text_IO;

with Version.Archive;
with Version.Repository;

procedure Bench_Archive is
   use type Ada.Calendar.Time;
   Output : constant String :=
     (if Ada.Command_Line.Argument_Count >= 1
      then Ada.Command_Line.Argument (1)
      else "version-bench-archive.tar");

   Revision : constant String :=
     (if Ada.Command_Line.Argument_Count >= 2
      then Ada.Command_Line.Argument (2)
      else "HEAD");

   Old_Dir : constant String := Ada.Directories.Current_Directory;
   Repo    : constant Version.Repository.Repository_Handle := Version.Repository.Open;
   Start   : Ada.Calendar.Time;
   Stop    : Ada.Calendar.Time;
begin
   Start := Ada.Calendar.Clock;
   Version.Archive.Create
     (Repository => Repo,
      Revision   => Revision,
      Output     => Output,
      Format     => Version.Archive.Tar_Format);
   Stop := Ada.Calendar.Clock;

   Ada.Text_IO.Put_Line ("bench_archive");
   Ada.Text_IO.Put_Line ("repository=" & Old_Dir);
   Ada.Text_IO.Put_Line ("revision=" & Revision);
   Ada.Text_IO.Put_Line ("output=" & Output);
   Ada.Text_IO.Put_Line ("elapsed_seconds=" & Duration'Image (Stop - Start));
end Bench_Archive;
