# Repository format

`version` operates directly on Git-compatible repository storage. It does not import or convert repositories.

Primary worktrees use a `.git/` directory. Linked worktrees use a `.git` file that points to a per-worktree admin directory. `Version.Repository` validates both forms and resolves the common repository directory.

The common repository directory owns shared `objects/`, `refs/`, `packed-refs`, `config`, `hooks/`, and `worktrees/`. Each worktree admin directory owns independent `HEAD`, `index`, sparse state, replay state, and submodule admin storage under its own `modules/` directory.

Loose objects and pack files use Git-compatible ids and compressed payloads. The index stores repository-relative `/` paths. Refs live in standard namespaces such as `refs/heads/`, `refs/tags/`, `refs/remotes/`, and `refs/stash`; ref names are validated for Git-like syntax and filesystem portability.

Unsupported format versions, unknown extensions, unsafe common-dir indirection, malformed submodule gitdir files, and unsupported repository features are rejected before higher-level mutation.

Depth-limited remote fetch/clone stores shallow boundaries in `.git/shallow`; maintenance treats those boundaries as protected roots. Sparse checkout state is worktree-local. Submodule admin directories are constrained below the current worktree admin directory's `modules/` tree.
