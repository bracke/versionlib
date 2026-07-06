# Worktrees

Commands:

```sh
version worktree add PATH BRANCH
version worktree add --detach PATH REV
version worktree list
version worktree current
version worktree remove PATH
```

A linked worktree has its own working directory, `.git` indirection file, admin directory, `HEAD`, index, sparse state, replay state, and submodule admin storage. It shares objects, refs, hooks, config, and common metadata with the main repository.

A branch should not be checked out in multiple worktrees simultaneously. `version worktree add PATH BRANCH` and branch-switch flows enforce branch occupancy. Detached worktrees are supported with `--detach`.

Removal validates linked metadata and rejects dirty or unsafe targets before cleanup.

`version worktree list` is a stable inspection surface. It labels the primary/current worktree, linked worktrees, missing linked paths, detached worktrees, and linked branch worktrees whose branch is therefore in use. Example labels include `[current primary] branch main`, `[linked branch-in-use] branch topic`, `[linked detached] detached 0123456789ab`, and `[linked missing branch-in-use] branch topic`. `version worktree current` prints only the current worktree with `[current primary]` or `[current linked]`.

Supported scope: add/list/current/remove, detached worktrees, shared object/ref store, per-worktree HEAD/index/sparse/replay/submodule-admin state, branch occupancy, and maintenance roots. Not claimed: full Git lock/prune/admin metadata parity, bare-worktree hybrids, or every reflog/config nuance.
