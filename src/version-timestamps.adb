with Ada.Calendar.Formatting;
with Ada.Calendar.Time_Zones;

package body Version.Timestamps is

   --  Midnight 1970-01-01 *at UTC* (Time_Zone => 0), not in the local zone.
   function Epoch return Ada.Calendar.Time is
     (Ada.Calendar.Formatting.Time_Of
        (Year       => 1970,
         Month      => 1,
         Day        => 1,
         Hour       => 0,
         Minute     => 0,
         Second     => 0,
         Sub_Second => 0.0,
         Time_Zone  => 0));

   function To_Unix (T : Ada.Calendar.Time) return Long_Long_Integer is
      Elapsed : constant Duration := Ada.Calendar."-" (T, Epoch);
      --  Ada rounds when converting a Duration to an integer, so a fractional
      --  second would round up and stamp the commit in the future. git floors.
      Whole   : constant Long_Long_Integer := Long_Long_Integer (Elapsed);
   begin
      if Duration (Whole) > Elapsed then
         return Whole - 1;
      end if;
      return Whole;
   end To_Unix;

   function Unix_Now return Long_Long_Integer is
   begin
      return To_Unix (Ada.Calendar.Clock);
   end Unix_Now;

   function Local_Zone return String is
      Offset : constant Integer :=
        Integer (Ada.Calendar.Time_Zones.UTC_Time_Offset);
      Sign   : constant Character := (if Offset < 0 then '-' else '+');
      Total  : constant Natural := abs Offset;

      function Pad (V : Natural) return String is
         Image : constant String := Natural'Image (V);
         Text  : constant String := Image (Image'First + 1 .. Image'Last);
      begin
         return (if Text'Length = 1 then "0" & Text else Text);
      end Pad;
   begin
      return Sign & Pad (Total / 60) & Pad (Total mod 60);
   exception
      when others =>
         return "+0000";
   end Local_Zone;

end Version.Timestamps;
