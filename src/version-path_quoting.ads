--  git's quote_c_style: how a path is printed when it contains bytes that
--  would be ambiguous or unreadable on a terminal.
package Version.Path_Quoting is

   function Quote_C_Style (Path : String) return String;
   --  Path unchanged when it needs no quoting, otherwise wrapped in double
   --  quotes with C escapes (`\t`, `\n`, `\"`, `\\`, and `\NNN` octal for
   --  anything else non-printable, including bytes with the high bit set --
   --  git's `core.quotePath` default).

   function Needs_Quoting (Path : String) return Boolean;

end Version.Path_Quoting;
