# Portability

Repository-internal paths use `/`; host paths must be built through `Version.Files`/`Version.Platform` helpers rather than ad hoc concatenation.

POSIX paths use `/` natively. Windows paths are normalized at command and scan boundaries so repository-relative paths stay `/`-separated. Ref names and filesystem components reject Windows-hostile names, forbidden characters, drive-relative forms, absolute paths, traversal components, `.git` escapes, and unsafe trailing dots or spaces.

`version` treats file contents as exact bytes and does not perform automatic CRLF conversion in this phase. Ordinary file staging writes `100644`, and executable regular files are staged as `100755` where the platform exposes executable-bit support. Platforms without executable-bit support continue to stage regular files as `100644`. On POSIX platforms, staging a symlink records the link target as a `120000` Git symlink entry, and checkout/restore materializes committed `120000` entries as symlinks. Platforms without supported symlink creation reject symlink checkout/restore materialization cleanly. Merge symlink materialization follows `core.symlinks`: `false` writes a plain link-target file, while enabled symlinks attempt host link creation and report creation failures.

The filesystem guard handles deterministic collision checks, including forced case-insensitive collision tests. Case-insensitive collision keys also fold common UTF-8 Latin composed/decomposed accent pairs before writes. POSIX guard checks reject symlinked parent components and symlinked delete targets before write/delete operations so repository actions do not follow links outside the working tree. Full host-specific Unicode normalization parity remains deferred. Recursive cleanup should use centralized helpers such as `Version.Files.Delete_Directory_Tree_If_Exists`; file replacement should use same-directory temporary files and atomic replacement where practical.


## Platform CI confirmation

The path-policy tests include simulation-level Windows checks and POSIX fixture checks, but release confirmation requires real-host execution. Run `tools/bin/check_platform_ci_matrix posix` on POSIX and `tools/bin/check_platform_ci_matrix windows` on native Windows. Collect and verify the generated evidence with `tools/bin/check_platform_ci_evidence`. See `docs/CI.md`.
