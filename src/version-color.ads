--  git's colour specifications: translate a config colour value such as
--  "red", "blue bold" or "#ff0000" into the ANSI escape sequence git would
--  emit for `git config --get-color`.
package Version.Color is

   function To_Ansi (Spec : String) return String;
   --  The ANSI escape (ESC "[" ... "m") for the git colour spec Spec, matching
   --  git's color_parse_mem: attributes first in table order, then the
   --  foreground colour, then the background. "normal" and the empty spec map
   --  to the empty string; "reset" maps to a bare "ESC [ m". Colours may be
   --  names (black..white, plus a "bright"/"bright " prefix), 256-colour
   --  numbers, or "#rrggbb"; attributes are bold, dim, italic, ul, blink,
   --  reverse and strike, each optionally negated with a "no"/"no-" prefix.

end Version.Color;
