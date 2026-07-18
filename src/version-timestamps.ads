with Ada.Calendar;

--  Unix time, the way git records it.
--
--  `Ada.Calendar.Time_Of (1970, 1, 1)` builds that date in the *local* zone,
--  so subtracting it from `Clock` yields seconds since local-midnight 1970 --
--  off by the zone's UTC offset as it stood in January 1970 (an hour in
--  central Europe, and not the current offset, because DST differs). Every
--  timestamp built that way lands in the future. Build the epoch at UTC
--  instead, which is what these subprograms do.
package Version.Timestamps is

   function To_Unix (T : Ada.Calendar.Time) return Long_Long_Integer;
   --  Seconds between the UTC Unix epoch and T.

   function Unix_Now return Long_Long_Integer;
   --  The current time as a Unix timestamp.

   function Local_Zone return String;
   --  The local UTC offset as git writes it next to a timestamp ("+0200").
   --  Falls back to "+0000" if the offset is unavailable.

end Version.Timestamps;
