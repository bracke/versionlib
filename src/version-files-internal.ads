private package Version.Files.Internal is

   procedure Validate_Atomic_Replace_Paths
     (Native_Source : String;
      Native_Target : String;
      Source_Temp   : String;
      Target        : String);

   procedure Delete_Source_On_Failure
     (Native_Source : String);

   procedure Atomic_Replace_Direct
     (Source_Temp : String;
      Target      : String);

end Version.Files.Internal;
