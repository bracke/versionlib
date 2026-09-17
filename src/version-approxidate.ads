--  git's approxidate: the loose date language `--since`, `--until`,
--  `--date`, `gc --prune` and friends accept -- "2 weeks ago",
--  "yesterday noon", "last monday", "2024-01-02", "Jan 2 2024", the strict
--  ISO 8601 / RFC 2822 forms, "@<unix>" and a bare unix time.
--
--  A port of date.c's parse_date_basic + approxidate_str: the strict forms
--  are tried first; otherwise the text is scanned token by token, numbers
--  and words updating a broken-down local time that starts as "now" with
--  the date fields unset, and every relative unit moves it into the past
--  (so "2 weeks" and "2 weeks ago" are the same, as in git).
package Version.Approxidate is

   --  The unix time Text names, relative to Now (a unix time; 0 takes the
   --  clock).  Recognized is False when no token made sense -- git then
   --  answers "now", which is what Result holds.
   procedure Parse
     (Text       : String;
      Result     : out Long_Long_Integer;
      Recognized : out Boolean;
      Now        : Long_Long_Integer := 0);

   --  Parse with the answer only (git's approxidate(): garbage is "now").
   function Value
     (Text : String; Now : Long_Long_Integer := 0) return Long_Long_Integer;

end Version.Approxidate;
