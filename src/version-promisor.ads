with Version.Repository;

package Version.Promisor is

   function Has_Promisor_Metadata
     (Repo : Version.Repository.Repository_Handle)
      return Boolean;

   function Fetch_Promised_Object
     (Repo : Version.Repository.Repository_Handle;
      Id   : String)
      return Boolean;

   function Missing_Object_Diagnostic
     (Repo : Version.Repository.Repository_Handle;
      Id   : String)
      return String;

end Version.Promisor;
