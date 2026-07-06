# Repository archives

`version archive` exports committed repository contents from object storage. It never consults the current working tree, the index, sparse-checkout state, or submodule working directories.

## Formats

Supported formats:

* TAR (`--format tar`, default)
* ZIP (`--format zip`)

Unsupported formats include `tar.gz`, `tgz`, `gz`, `tar.xz`, `txz`, `xz`, `tar.bz2`, `tbz`, `tbz2`, `bz2`, `zipx`, `7z`, and `rar`. Output names with those suffixes are rejected at both CLI and archive API level instead of silently writing an uncompressed TAR/ZIP with a compressed-looking name. Diagnostics suggest the supported `.tar`/`.zip` output names and the explicit `--format tar|zip` option.

## Revision source

The command resolves the requested revision to a tree object, walks the tree recursively, reads blobs directly from the object database, and writes archive entries. Uncommitted changes are not included.

```sh
version archive HEAD --output source.tar
version archive v1.0 --format zip
version archive main --output release.zip
version archive HEAD --prefix release/
version archive HEAD -- --literal-pathspec-that-starts-with-dash
```

## Archive prefix

`--prefix DIR/` places every emitted archive entry below a deterministic root directory. The prefix is archive metadata only: it is applied after revision resolution and pathspec matching, and it never changes repository paths or pathspec interpretation. A prefix of `release/` exports `src/main.adb` as `release/src/main.adb`; filtering with `src/` still matches the original repository path. The root prefix directory is emitted explicitly so extractors create a stable top-level directory.

Archive prefixes must be relative forward-slash paths. Absolute prefixes, backslashes, NUL/control characters, empty components, `.` components, `.git` components, and `..` traversal components are rejected. Prefix diagnostics identify the failing component where possible. A trailing slash is accepted and normalized for output.

## Path filtering

Pathspec arguments restrict the exported entries.

```sh
version archive HEAD src/
version archive HEAD --output docs.zip --format zip docs/
```

The tree is still resolved from the selected revision; pathspecs only filter which entries are emitted.

## Submodules

Gitlink entries are not archived recursively. Version emits a placeholder file at the gitlink path containing the referenced commit id so archive consumers can see that the submodule existed. Git symlink entries (`120000`) are exported as archive symlink metadata: TAR uses a typeflag-2 link header and ZIP stores the link target with Unix symlink mode metadata. The gitlink placeholder content is deterministic:

```text
Submodule: <commit-id>
```

The submodule working directory is never inspected.

## Format details

TAR output is uncompressed ustar-style output for regular files, explicit trailing-slash directories, and symlinks. It preserves executable file mode metadata, supports ustar name/prefix splitting for longer paths, rejects absolute, backslash, NUL/control-character, empty-component, `.` and `..` archive names, rejects unsafe symlink targets, rejects duplicate archive entry names and directory/file name collisions, and uses fixed timestamps for deterministic output.

ZIP output uses ZIP method 8 with raw deflate streams produced through the integrated Ada Zlib infrastructure. The current deflate encoder emits stored deflate blocks, so entries are valid deflated ZIP members without content transformation. Directory entries are stored with explicit trailing-slash names, symlink entries store their link target with Unix symlink mode metadata, and file entries preserve CRC-32, byte size, Unix mode metadata, and deterministic timestamps. ZIP names are likewise validated as relative forward-slash paths and reject absolute, backslash, NUL/control-character, empty-component, `.` and `..` names; symlink targets reject absolute, traversal, backslash, NUL/control-character, and empty-component targets. ZIP also rejects duplicate archive entry names and directory/file name collisions through a command-local ordered name set before writing central-directory metadata. Empty ZIP files and empty directories are represented explicitly. ZIP compression still uses the current zlib helper interface, so individual file payloads are compressed as complete blob contents; Phase 41 avoids archive-wide duplicate scans but does not introduce a streaming deflate encoder.

The output file path must name a file, not a directory, and cannot be empty or contain a NUL character. Archive data is written to a same-directory temporary output and atomically replaces the requested output only after the TAR/ZIP writer closes successfully. If export fails because of hostile tree data, unsafe symlink targets, unsupported object modes, or other archive errors, the temporary output is removed and any preexisting output file is preserved. The CLI validates archive usage before opening a repository, so `version archive` with no revision reports the archive usage form even outside a worktree. It rejects unknown `--long-option` arguments before `--` instead of treating them as pathspecs, which keeps option mistakes deterministic.

## Determinism

Archive writers use deterministic metadata where practical: fixed timestamps, stable tree traversal order from repository tree decoding, and committed blob bytes without newline or encoding conversion. Identical committed trees produce stable archive entry order and metadata.

## Completeness checks

The archive regression suite covers HEAD, tag, and branch revision selection; dirty working-tree independence; sparse-checkout independence; pathspec inclusion/exclusion and no-match behavior; unsafe archive entry and symlink-target rejection including control characters, empty path components, and regular-file names ending in slash; unsafe symlink targets loaded from committed object data; duplicate entry-name and directory/file collision rejection; output path validation; case-insensitive unsupported compressed output rejection; deterministic repeated TAR/ZIP generation; long TAR ustar paths; TAR and ZIP extraction of binary, CRLF, and compressed-looking bytes; executable-mode metadata; gitlink placeholder emission; symlink metadata preservation; empty output-path rejection; empty ZIP directory/file writing; explicit TAR/ZIP directory entries; archive prefix root rewriting and unsafe-prefix rejection; empty filtered archives; unsupported tree file-mode rejection; failed-export temporary-output cleanup; preservation of preexisting output files after failed exports; and TAR/ZIP file-set and byte-preservation equivalence.
