with Version.Hash;

package Version.Init is

   procedure Init
      (Path          : String := ".";
       Object_Format : Version.Hash.Hash_Algorithm := Version.Hash.Sha1);

   procedure Init_Bare
      (Path          : String := ".";
       Object_Format : Version.Hash.Hash_Algorithm := Version.Hash.Sha1);

end Version.Init;
