with Ada.Strings.Unbounded;

package Version.Doctor is

   type Check_Status is
     (Pass,
      Warn,
      Fail);

   type Doctor_Result is record
      Repository_Status : Check_Status := Fail;
      Object_Format_Status : Check_Status := Fail;
      Head_Status : Check_Status := Fail;
      Index_Status : Check_Status := Fail;
      Message : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   function Check_Repository return Doctor_Result;

   function Result_Text
     (Result : Doctor_Result)
      return String;

   function Release_Check_Text return String;

   function Run_Release_Checks return Boolean;

end Version.Doctor;
