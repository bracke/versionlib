with Ada.Containers.Indefinite_Vectors;
with Ada.Strings.Unbounded;

--  Mailed patches: splitting an mbox into messages (`mailsplit`) and pulling
--  the authorship, subject, commit message and patch out of one (`mailinfo`).
--  `am` is the same two steps followed by an apply.
package Version.Mailbox is

   use Ada.Strings.Unbounded;

   package Text_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type   => Positive,
      Element_Type => String);

   type Message is record
      --  "Name <mail@example.com>", as the From: header spelled it.
      Author       : Unbounded_String;
      Author_Name  : Unbounded_String;
      Author_Email : Unbounded_String;
      --  The Date: header, verbatim.
      Date         : Unbounded_String;
      --  The subject with a leading "[PATCH ...] " tag removed.
      Subject      : Unbounded_String;
      --  The commit message below the subject, verbatim -- the bytes
      --  `mailinfo` writes to its message file, trailing blank lines and all.
      Body_Text    : Unbounded_String;
      --  Everything from the "---" line on: what `mailinfo` writes to its
      --  patch file.
      Patch        : Unbounded_String;
   end record;

   --  An mbox "From " line, by git's rule (mailsplit.c): "From ", then a date
   --  whose time has digits around a colon.  git's format-patch writes the
   --  commit id there, but any mbox From line counts.
   function Is_From_Line (Line : String) return Boolean;

   --  One entry per message, each the message's own text.
   function Split (Mailbox : String) return Text_Vectors.Vector;

   function Parse (Mail : String) return Message;

end Version.Mailbox;
