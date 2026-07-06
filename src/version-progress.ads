package Version.Progress is

   type Sink is limited interface;

   procedure Message
     (Item : in out Sink;
      Text : String) is abstract;

end Version.Progress;
