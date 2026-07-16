with Version.Repository;

--  git URL rewriting via `url.<base>.insteadOf` / `url.<base>.pushInsteadOf`
--  config. When a URL begins with a configured insteadOf value, that prefix is
--  replaced by <base>; the longest matching prefix wins. For push URLs, any
--  matching pushInsteadOf takes precedence over insteadOf.
package Version.Url_Rewrite is

   function Rewrite
     (Repo     : Version.Repository.Repository_Handle;
      Url      : String;
      For_Push : Boolean := False)
      return String;
   --  Return Url with the best-matching insteadOf (or pushInsteadOf, when
   --  For_Push) rewrite applied, or Url unchanged when none matches.

end Version.Url_Rewrite;
