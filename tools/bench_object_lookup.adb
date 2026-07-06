with Ada.Calendar;
with Ada.Command_Line;
with Ada.Directories;
with Ada.Text_IO;

with Version.Object_Cache;
with Version.Objects;
with Version.Refs;
with Version.Repository;

procedure Bench_Object_Lookup is
   use type Ada.Calendar.Time;
   Iterations : constant Positive :=
     (if Ada.Command_Line.Argument_Count >= 1
      then Positive'Value (Ada.Command_Line.Argument (1))
      else 1000);

   Old_Dir : constant String := Ada.Directories.Current_Directory;
   Repo    : constant Version.Repository.Repository_Handle := Version.Repository.Open;
   Head    : constant String := Version.Refs.Current_Commit_Id (Repo);
   Id      : constant Version.Objects.Hex_Object_Id := Version.Objects.To_Object_Id (Head);
   Cache   : Version.Object_Cache.Object_Cache;
   Start   : Ada.Calendar.Time;
   Stop    : Ada.Calendar.Time;
   Obj     : Version.Objects.Git_Object;
begin
   if not Version.Objects.Is_Valid_Hex_Object_Id (Head) then
      Ada.Text_IO.Put_Line ("HEAD does not point to an object");
      return;
   end if;

   Start := Ada.Calendar.Clock;
   for I in 1 .. Iterations loop
      Obj := Version.Object_Cache.Read_Object (Repo, Cache, Id);
   end loop;
   Stop := Ada.Calendar.Clock;

   Ada.Text_IO.Put_Line ("bench_object_lookup");
   Ada.Text_IO.Put_Line ("repository=" & Old_Dir);
   Ada.Text_IO.Put_Line ("iterations=" & Positive'Image (Iterations));
   Ada.Text_IO.Put_Line ("head_kind=" & Version.Objects.Object_Kind'Image (Version.Objects.Kind (Obj)));
   Ada.Text_IO.Put_Line ("elapsed_seconds=" & Duration'Image (Stop - Start));
end Bench_Object_Lookup;
