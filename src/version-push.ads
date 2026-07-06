package Version.Push is

   function Invalid_Remote_Branch_Commit_Id_Diagnostic return String;

   function Invalid_Remote_Tag_Object_Id_Diagnostic return String;

   function Remote_Branch_Changed_During_Push_Diagnostic return String;

   function Remote_Tag_Changed_During_Push_Diagnostic return String;

   procedure Push
     (Remote_Name : String;
      Branch_Name : String;
      Run_Hooks   : Boolean := True;
      Force       : Boolean := False);
   --  Force skips the fast-forward (ancestor) check, allowing a non-fast-
   --  forward branch update on the remote.

   procedure Push_Tags
     (Remote_Name : String;
      Run_Hooks   : Boolean := True;
      Force       : Boolean := False);
   --  Force overwrites remote tags that differ from the local tag.

   procedure Delete_Ref
     (Remote_Name : String;
      Ref_Name    : String;
      Run_Hooks   : Boolean := True);
   --  Delete Ref_Name (e.g. "refs/heads/x" or "refs/tags/v1") on the remote
   --  over local, HTTP, or SSH transport. Errors if the ref is absent.

   procedure Push_Refspec
     (Remote_Name : String;
      Source      : String;
      Dest_Ref    : String;
      Force       : Boolean := False;
      Run_Hooks   : Boolean := True);
   --  Push the commit named by Source (a local rev) to Dest_Ref (a full ref
   --  such as "refs/heads/x" or "refs/tags/v1") on the remote over local,
   --  HTTP, or SSH transport. Refuses a non-fast-forward update unless Force.

   procedure Push_Default
     (Remote_Name : String;
      Run_Hooks   : Boolean := True);
   --  Push using the configured "remote.<Remote_Name>.push" refspec(s), each
   --  parsed like a command-line refspec (a leading "+" forces, an empty
   --  source deletes the destination). Errors if none are configured.

end Version.Push;