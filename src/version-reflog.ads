with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;
with Version.Repository;

package Version.Reflog is

   type Lock_Error_Kind is (Data_Error_On_Lock, Use_Error_On_Lock);

   --  A parsed reflog line. Old_Id/New_Id are the object ids the ref moved
   --  between; Message is the text after the tab (e.g. "reset: moving to X").
   type Log_Entry is record
      Old_Id  : Ada.Strings.Unbounded.Unbounded_String;
      New_Id  : Ada.Strings.Unbounded.Unbounded_String;
      Message : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   package Log_Entry_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Log_Entry);

   --  Parse the reflog for Ref, oldest entry first (so the last element is the
   --  most recent, i.e. @{0}). Returns an empty vector when no reflog exists.
   function Read_Entries
     (Repo : Version.Repository.Repository_Handle;
      Ref  : String := "HEAD")
      return Log_Entry_Vectors.Vector;

   function Path
     (Repo : Version.Repository.Repository_Handle;
      Ref  : String) return String;

   procedure Preflight_Append
     (Repo       : Version.Repository.Repository_Handle;
      Ref        : String;
      Error_Kind : Lock_Error_Kind := Data_Error_On_Lock);

   procedure Append
     (Repo    : Version.Repository.Repository_Handle;
      Ref     : String;
      Old_Id  : String;
      New_Id  : String;
      Message : String);

end Version.Reflog;