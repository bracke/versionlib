package Version.Clone is

   procedure Clone
     (Source : String;
      Target : String);

   procedure Clone
     (Source : String;
      Target : String;
      Depth  : Positive);

   procedure Clone_Filtered
     (Source : String;
      Target : String;
      Filter : String);
   --  Partial clone applying a filter spec (e.g. "blob:none" or
   --  "blob:limit=<n>"); the repository is configured as a partial clone so
   --  omitted objects are lazily fetched from origin on first access.

end Version.Clone;
