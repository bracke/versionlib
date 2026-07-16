with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

package Version.Push is

   --  One entry of an atomic push: update Dest_Ref to the commit named by
   --  Source, or (when Delete) remove Dest_Ref on the remote.
   type Atomic_Command is record
      Source   : Ada.Strings.Unbounded.Unbounded_String;
      Dest_Ref : Ada.Strings.Unbounded.Unbounded_String;
      Delete   : Boolean := False;
   end record;

   package Atomic_Command_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Atomic_Command);

   procedure Push_Atomic
     (Remote_Name : String;
      Commands    : Atomic_Command_Vectors.Vector;
      Force       : Boolean := False;
      Run_Hooks   : Boolean := True);
   --  Apply every command to the remote atomically (all-or-nothing): locally
   --  via one ref transaction; over HTTP/SSH via a single receive-pack request
   --  using the `atomic` capability. Non-fast-forward updates are rejected
   --  before anything is applied unless Force.

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

   --  Like Push_Refspec, but Repository may be a path or URL that is not a
   --  configured remote (`send-pack <url> <refspec>`): it is registered just
   --  for the push and taken away again.
   procedure Push_Refspec_To
     (Repository : String;
      Source     : String;
      Dest_Ref   : String;
      Force      : Boolean := False;
      Run_Hooks  : Boolean := True);

   procedure Push_Default
     (Remote_Name : String;
      Run_Hooks   : Boolean := True);
   --  Push with no explicit refspec. If "remote.<Remote_Name>.push" refspec(s)
   --  are configured, apply them (each parsed like a command-line refspec: a
   --  leading "+" forces, an empty source deletes the destination). Otherwise
   --  fall back to push.default (git's default is "simple"): "current" pushes
   --  the current branch to a same-named remote branch; "upstream"/"tracking"
   --  push it to its configured upstream branch; "simple" behaves like
   --  "upstream" but refuses when the upstream branch name differs; "nothing"
   --  errors. A missing upstream (upstream/simple) or a detached HEAD errors.
   --  ("matching" is handled by Push_Matching.)

   procedure Push_Matching
     (Remote_Name : String;
      Force       : Boolean := False;
      Run_Hooks   : Boolean := True);
   --  git's "matching" push (the bare `:` refspec and push.default=matching):
   --  update every remote branch that shares a name with a local branch. New
   --  remote branches are not created; a no-op when nothing matches.

end Version.Push;