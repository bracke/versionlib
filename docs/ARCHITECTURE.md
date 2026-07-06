# Architecture

`version` is organized around explicit Ada package ownership. `Version.CLI` parses arguments and delegates; repository mutation belongs to the package that owns the domain.

## Crate layout

The project is split into two Alire crates:

* **`versionlib`** (`../versionlib`) is a library crate holding all functionality — every `Version.*` package (storage, refs, transports, replay operations, etc.). It depends on `httpclient`, `zlib`, `i18n`, and `ssh_lib`.
* **`version`** (this crate) is the executable. It contains only `src/main.adb` and `Version.CLI` (with `Version.CLI.Arguments/Help/Progress`), depends on `versionlib`, and implements each command by calling library functions. No `versionlib` package depends on the CLI.

New behavior is added in `versionlib` and then wired into the CLI here. The package ownership described below applies to the `versionlib` sources.

## Core storage

* `Version.Repository` discovers primary, bare, and linked-worktree repositories and exposes root/common/admin paths.
* `Version.Repository_Format` rejects unsupported repository format versions or extensions.
* `Version.Objects` reads/writes and interprets Git objects.
* `Version.Object_Cache` provides command-local object caching and uses cached pack-index locations for packed objects.
* `Version.Tree_Cache` provides command-local tree flattening caches for status, diff, archive, and maintenance paths that repeatedly inspect the same tree.
* `Version.Ref_Cache` provides command-local ref resolution caching for command pipelines that repeatedly resolve HEAD or named refs.
* `Version.Pack` reads pack/index files; `Version.Pack_Index_Cache` loads pack index metadata once per command, provides object-id location lookup, exposes diagnostic cache counts, and participates in abbreviated revision resolution without reading object contents. `Version.Pack_Write` writes pack/index output by streaming PACK bytes to disk while maintaining an incremental SHA-1 trailer; it does not retain the full pack body in memory before writing.
* `Version.Compression` and `Zlib.*` provide object/pack compression support.

## Working tree and paths

* `Version.Staging` owns index load/update/write behavior.
* `Version.Working_Tree` scans working files and reports repository-relative paths. During ignored scans it builds a command-local tracked-path index so tracked exceptions, gitlinks, and tracked directory prefixes are checked by lookup instead of repeated index walks.
* `Version.Path_Safety` validates repository-relative paths and rejects traversal, absolute paths, `.git` escapes, and platform-unsafe forms.
* `Version.Filesystem_Guard` preflights working-tree write/delete plans before mutation.
* `Version.Pathspec` parses and matches supported pathspecs; callers own candidate discovery.
* `Version.Ignore`, `Version.Files`, and `Version.Platform` centralize ignore and portability helpers. `Version.Ignore` resolves `core.excludesFile` through Git's system/global/local plus command-scope environment config stack, following `[include] path`, matching `[includeIf "gitdir:..."] path`, matching `[includeIf "onbranch:..."] path`, and matching `[includeIf "hasconfig:remote.*.url:..."] path` config files with a bounded recursion depth, falls back to Git's default global ignore file when that key is unset, expands `%(prefix)` in config-derived ignore paths, then loads local `.git/info/exclude` and repository `.gitignore` files in increasing precedence so later sources retain normal override behavior. `Version.Files.Atomic_Replace` is the normal replacement API; `Version.Files.Rollback` owns the backup-rollback fallback surface and rollback artifact naming used by focused platform tests.

## Refs and history

* `Version.Refs`, `Version.Ref_Names`, `Version.Ref_Transaction`, `Version.Reflog`, and `Version.Packed_Refs` own refs, HEAD, ref validation, atomic updates, reflogs, and packed refs. `Version.Ref_Transaction` validates expected-old values before mutation, acquires loose ref locks, rewrites `packed-refs` for transactional deletes that target packed entries, and only then applies loose ref updates/deletes.
* `Version.Revisions` resolves revision text to commits.
* `Version.History` performs ancestry, merge-base, and reachable-object walks with command-local object and shallow-boundary caches plus ordered object-id sets for seen/pending membership; it avoids repeated object-store reads, shallow-file rereads, and repeated vector membership scans during large history traversals.
* `Version.Tracking` owns upstream/ahead/behind calculations. Phase 41 keeps these branch-tracking walks command-local by reusing object and shallow-boundary caches and by using ordered object-id sets for seen, pending, and difference membership instead of repeated reachable-vector scans.
* `Version.Log`, `Version.Show`, and `Version.Diff` are read/projection packages. Diff builds ordered side/path maps before content reads so path classification remains deterministic without quadratic side lookups.

## Commands and workflows

* `Version.Init`, `Version.Write`, `Version.Restore`, `Version.Checkout`, `Version.Branch`, `Version.Tags`, `Version.Remove`, and `Version.Status` own ordinary repository workflows.
* `Version.Rebase`, `Version.Cherry_Pick`, `Version.Revert`, and their state packages own replay start/continue/abort semantics.
* `Version.Stash` owns `refs/stash` and stash apply/pop/drop behavior.

## Remotes and transports

* `Version.Remotes` owns remote configuration.
* `Version.Transport` dispatches local, HTTP, and SSH transport implementations.
* `Version.Transport.Local`, `Version.Transport.Http`, and `Version.Transport.Ssh` own their scheme-specific behavior.
* `Version.Pkt_Line`, `Version.Upload_Pack`, and `Version.Receive_Pack` own smart protocol framing. `Version.Receive_Pack` builds HTTP push requests from generated pack files without retaining both a separate whole-pack buffer and a second whole-request copy.
* `Version.Fetch`, `Version.Push`, and `Version.Clone` orchestrate high-level transfer and checkout/finalization order.

## Layout features

* `Version.Shallow` owns `.git/shallow` state. `Version.Shallow_Cache` provides command-local shallow-boundary caching for log, history, maintenance, and reachability walks so large shallow repositories do not reread the shallow file for every commit boundary check.
* `Version.Sparse` owns sparse-checkout configuration.
* `Version.Worktrees` owns linked worktree add/list/remove, metadata validation, and branch occupancy.
* `Version.Gitmodules` parses `.gitmodules`; `Version.Submodules` owns submodule init/update/status and gitlink handling.

## Hooks and maintenance

* `Version.Hooks` runs the supported client-side hook allow-list through direct process arguments.
* `Version.Maintenance`, `Version.Reachability`, `Version.Object_Cache`, `Version.Tree_Cache`, `Version.Ref_Cache`, and `Version.Pack_Index_Cache` own verification, repack, prune, gc, and traversal support. Reachability traversal keeps command-local ordered object-id sets for seen/pending membership and a command-local shallow-boundary cache; history traversal uses the same command-local set/cache discipline for ancestry and merge-base walks; prune uses set membership for reachable-object filtering and cached shallow-boundary checks; repack verification reloads the generated pack indexes once rather than repeatedly scanning pack indexes per object.

## Extension rules

New features should update command help, docs, compatibility matrix, tests, and release checks. Use `Version.Files`, `Version.Path_Safety`, `Version.Ref_Names`, and `Version.Filesystem_Guard` for portability/security-sensitive paths. Do not add alternate mutation paths in docs, tools, or read-only projection packages.


## Archive export

`Version.Archive` owns revision-to-tree export. It delegates format-specific serialization to `Version.Tar` and `Version.Zip`, while repository traversal remains centralized and reads blob contents directly from `Version.Objects`. Archive generation does not materialize a checkout and is independent of index, sparse checkout, worktree, and submodule working-directory state. Optional archive prefixes are applied after pathspec matching as output-name rewriting only. Phase 41 keeps the archive traversal command-local: selected entries are computed once, explicit parent directories are de-duplicated through an ordered set, and ZIP duplicate-entry detection uses an ordered name set instead of repeatedly scanning the central-directory vector.



### Phase 41 loose-object discovery scalability

Maintenance and prune flows discover loose objects by walking `.git/objects`. Phase 41 keeps this discovery command-local and deterministic while using an ordered object-id set for membership, so uniqueness checks do not degrade into repeated vector scans as loose-object directories grow.

### Phase 41 deterministic ordering scalability

Phase 41 keeps user-visible output ordering deterministic without using quadratic hand-written sorts on common large-repository vectors. Status change lists, diff side vectors, index-entry ordering, and shallow object-id persistence now use Ada container generic sorting with the same path/object comparison rules as before. This keeps command semantics and output order unchanged while avoiding avoidable repeated swaps as repositories grow.

### Phase 41 pathspec-aware status and diff scans

`Version.Status.Current_Status (Pathspecs)` routes working-tree enumeration through the pathspec-aware `Version.Working_Tree.Scan` overload. The scan remains conservative about directory traversal so later matching descendants are not missed, but ordinary files and gitlink directories that cannot contribute to the requested pathspecs are not hashed or appended to the working-file vector. Final status classification still uses the existing deterministic path maps and output filtering, preserving status semantics while avoiding unnecessary content reads for path-filtered status commands.

`Version.Diff.Diff_Working_Tree (Pathspecs)` uses the same pathspec-aware scan with command-local ignore rules and tracked index entries, then applies final pathspec filtering to both old and new diff sides. Tracked working-tree matching is indexed through an ordered map, avoiding one linear working-side search per index entry while preserving deterministic diff path order and omission of untracked files from ordinary working-tree diffs.


### Phase 41 restore cache-aware tree materialization

`Version.Restore` now uses command-local object and tree caches while resolving target commits, flattening target trees, and writing restored blobs. Full working-tree restore builds an ordered target-tree path map once and uses that map while comparing the existing index to the target tree, avoiding repeated linear tree membership scans when removing paths that are present only in the current index. Restore preflight, filesystem guard validation, sparse inclusion checks, and deterministic tree traversal order remain unchanged.

`Version.Checkout` now supplies a shared command-local object/tree cache pair to restore operations during full commit checkout and single-path checkout. This keeps target commit validation, working-tree materialization, and index materialization on the same cache lifetime, so the checkout path does not re-read the target commit or re-flatten the target tree between related restore steps. The existing detached-HEAD write, reflog append, hook dispatch, path safety, sparse checks, and filesystem guard behavior remain unchanged.


### Phase 41 replay and stash cache-aware tree setup

`Version.Cherry_Pick`, `Version.Revert`, `Version.Rebase`, and `Version.Stash` now use command-local object and tree caches while preparing three-way merge inputs. Replay/apply operations reuse cached commit reads and flattened base/current/target trees when restoring the replay parent or current HEAD, writing the corresponding index, and materializing the final replay result. This preserves existing conflict-state, reflog, hook, and working-tree semantics while avoiding repeated object-store reads and tree flattening inside one replay/apply command.

### Phase 41 branch integration cache-aware tree setup

`Version.Branch` now reuses command-local object and tree caches while preparing merge/integration tree inputs. Integration abort cleanup builds an ordered set of current-parent paths before removing target-only files, avoiding repeated flattened-tree membership scans while preserving path-safety checks and the existing current-parent restore semantics.

### Phase 41 streaming pack writer

`Version.Pack_Write` writes the PACK header, each compressed object entry, and the final trailer directly to the target pack file.  A command-local `Version.Object_Cache.Object_Cache` prevents repeated object-store lookups while preparing entries, and `Version.Hash.Sha1_Context` tracks the pack checksum incrementally.  The writer still builds the small IDX metadata tables after the pack checksum is known, but it no longer materializes a complete PACK body string before writing the file.  Individual object payload/compression buffers remain bounded to one object at a time.

### Phase 41 streaming fetch path

HTTP fetch now keeps discovery parsing as a small collected metadata step, but the upload-pack result body is consumed incrementally.  Response chunks are fed into a pkt-line parser, side-band channel 1 bytes are written directly to `objects/pack/tmp-version-fetch.pack`, shallow/unshallow metadata is accumulated as it arrives, and the pack is indexed only after the stream is closed.  This preserves existing fetch semantics while avoiding an in-memory copy of the complete upload-pack response or complete pack payload.

### Phase 41 receive-pack request buffering

`Version.Receive_Pack.Build_Request_From_Pack_File` appends the generated temporary pack file directly into the final smart-HTTP receive-pack request buffer after the update command and flush packet.  The current HTTP client API still requires one request payload object for the POST, but the push path no longer creates an intermediate full-pack byte array before constructing that payload.  This keeps push memory growth to one final HTTP payload plus the on-disk temporary pack, while preserving the existing report-status parsing and ref-update semantics.


#### Phase 41 command-local ref cache expansion

`Version.Ref_Cache` now owns a command-local ordered map of packed refs in addition to resolved loose/ref-name results. The cache loads `packed-refs` lazily on first packed lookup and keeps that view stable until `Clear` is called. Revision resolution uses `Try_Resolve_Ref` so short branch/tag/remote-name probing does not repeatedly parse `packed-refs`.

### Phase 41 shallow-boundary update scaling

Shallow repository metadata remains file-backed and command-local.  Phase 41 paths that normalize `.git/shallow` or apply smart-HTTP shallow/unshallow responses use ordered object-id sets to avoid repeated vector scans while preserving sorted deterministic writes.  The optimization does not introduce persistent shallow state; cache lifetime remains bounded to the command or metadata update operation.
