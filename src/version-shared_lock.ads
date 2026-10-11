with Ada.Finalization;

--  The one lock over what the library keeps between calls: the configuration
--  last read, pack listings, indexes and data, loose objects, flattened
--  trees. A program that calls the library from several tasks gets each
--  cache whole, never half rewritten by another task.
--
--  It is held by declaring a Hold, for as long as the Hold lives; a task
--  that holds it may take it again (the library calls itself), and the
--  library starts no task of its own, so it cannot wait on itself.
package Version.Shared_Lock is

   type Hold is new Ada.Finalization.Limited_Controlled with null record;
   overriding procedure Initialize (Item : in out Hold);
   overriding procedure Finalize (Item : in out Hold);

end Version.Shared_Lock;
