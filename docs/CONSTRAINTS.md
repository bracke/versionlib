No Git awareness inside Zlib. No external zlib dependency. Ada-only tests.

## Phase 22 filemode constraint

Tree and index entries continue to preserve stored modes during tree reads, restore, checkout, and index reconstruction. New staging records `100755` for executable regular files on platforms where executable-bit support is available, and records `100644` on platforms without executable-bit support. Platforms without executable-bit support must not fail merely because an existing tree/index entry carries `100755`; the metadata is preserved even when filesystem permission restoration is deferred.
