# Submodules

Commands:

```sh
version submodule init
version submodule update [--recursive]
version submodule status
```

A submodule is described by a safe `.gitmodules` entry and a gitlink entry in the index/tree. The gitlink records the submodule commit. Submodule admin data is constrained under the current worktree admin directory's `modules/` tree; for primary worktrees that is `.git/modules/`, while linked worktrees use their linked admin directory.

The `.gitmodules` parser accepts the conservative subset needed for practical workflows and rejects malformed or unsafe entries, unsafe paths, control characters, duplicate unsupported shapes, and escaping gitdir metadata. `version submodule update` resolves common relative URLs (`../lib.git`, `../../shared/repo.git`, and `./nested.git`) against the superproject's configured remote URL before cloning. Supported bases include local paths, `file://` URLs, HTTP(S) URLs, `ssh://` URLs, and scp-like SSH remotes. A relative URL without a configured superproject remote is rejected before mutation.

`version submodule update` initializes and checks out submodule content to the commit recorded by the superproject. `--recursive` updates nested supported submodules. Planned submodule worktree paths are preflighted as directory targets before mutation.

Not claimed: full Git URL rewriting, branch-tracking submodule workflows, deinit/sync/foreach, or full nested edge-case parity.
