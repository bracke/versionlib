with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Version.Objects;
use type Version.Objects.Object_Id_Storage;

--  Git-compatible rename detection: a port of git's diffcore-delta.c
--  (content similarity) and the pairing passes of diffcore-rename.c, so that
--  the `similarity index NN%` we print is the number git prints.
package Version.Rename_Detect is

   use Ada.Strings.Unbounded;

   --  git's diffcore.h: scores run 0 .. Max_Score, and the default rename
   --  threshold is half of it.
   Max_Score            : constant := 60_000;
   Default_Rename_Score : constant := 30_000;   --  50%
   Default_Rename_Limit : constant := 1_000;

   function Similarity_Index (Score : Natural) return Natural
     is (Score * 100 / Max_Score);
   --  git's similarity_index(): truncating, not rounding.

   function Is_Binary (Content : String) return Boolean;
   --  git's buffer_is_binary(): a NUL within the first 8000 bytes. Note this
   --  deliberately ignores NULs beyond that point, as git does.

   function Estimate_Similarity
     (Source        : String;
      Dest          : String;
      Minimum_Score : Natural := Default_Rename_Score)
      return Natural;
   --  git's estimate_similarity(): how much of Dest came from Source, as a
   --  score in 0 .. Max_Score. Includes git's size-delta short circuit, so a
   --  score of 0 may mean "too different to be worth measuring".

   --  One side of the rename search. Mode is the octal text ("100644"), used
   --  to apply git's rule that only regular files take part in inexact
   --  matching (symlinks and gitlinks rename only on an exact content match).
   type Rename_Side is record
      Path : Unbounded_String;
      Id   : Version.Objects.Object_Id_Storage;
      Mode : Unbounded_String;
   end record;

   package Side_Vectors is new Ada.Containers.Vectors
     (Index_Type => Natural, Element_Type => Rename_Side);

   --  A detected rename: indices into the Sources and Dests vectors given to
   --  Detect, plus the similarity score that pairing settled on.
   type Rename_Pair is record
      Source : Natural := 0;
      Dest   : Natural := 0;
      Score  : Natural := 0;
   end record;

   package Pair_Vectors is new Ada.Containers.Vectors
     (Index_Type => Natural, Element_Type => Rename_Pair);

   --  Generic over the content lookup because the destination side may live
   --  in the working tree rather than in an object, so the caller -- not an
   --  object id alone -- decides where the bytes come from.
   generic
      with function Content_Of (Side : Rename_Side) return String;
   function Detect
     (Sources       : Side_Vectors.Vector;
      Dests         : Side_Vectors.Vector;
      Minimum_Score : Natural := Default_Rename_Score;
      Rename_Limit  : Natural := Default_Rename_Limit)
      return Pair_Vectors.Vector;
   --  Pair deleted paths (Sources) with created paths (Dests) as git's
   --  diffcore_rename does: an exact pass on identical blob ids first, then an
   --  inexact pass that scores the remaining cross product and greedily
   --  assigns the best pairs. Each source and each destination is used at most
   --  once. Returns the pairs in destination order.
   --
   --  Content_Of is called only for the inexact pass, so an exact-match-only
   --  history never reads a blob. When Rename_Limit is non-zero and
   --  Sources'Length * Dests'Length exceeds its square, the inexact pass is
   --  skipped entirely (git's rename limit); exact matches are still reported.

end Version.Rename_Detect;
